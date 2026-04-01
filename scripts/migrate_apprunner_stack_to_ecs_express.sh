#!/usr/bin/env bash
set -euo pipefail

resolve_bin() {
  local name="$1"
  shift

  if command -v "${name}" >/dev/null 2>&1; then
    command -v "${name}"
    return 0
  fi

  local candidate
  for candidate in "$@"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  echo "Unable to find required binary: ${name}" >&2
  exit 1
}

AWS_BIN="${AWS_BIN:-$(resolve_bin aws /opt/homebrew/bin/aws /usr/local/bin/aws)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-}"
ECS_CLUSTER="${ECS_CLUSTER:-mini-load-balancer-express}"

BACKEND_A_APP_RUNNER_ARN="${BACKEND_A_APP_RUNNER_ARN:-arn:aws:apprunner:us-east-1:194191749520:service/mini-load-balancer-backend-a/f967a656457845f6a33f9aa3ad85199e}"
BACKEND_B_APP_RUNNER_ARN="${BACKEND_B_APP_RUNNER_ARN:-arn:aws:apprunner:us-east-1:194191749520:service/mini-load-balancer-backend-b/845e84ec34eb4b149fe55c45be2dfa56}"
LB_APP_RUNNER_ARN="${LB_APP_RUNNER_ARN:-arn:aws:apprunner:us-east-1:194191749520:service/mini-load-balancer/3a9e9bac11a3471d90fbe874379f609e}"

EXECUTION_ROLE_NAME="${EXECUTION_ROLE_NAME:-ecsTaskExecutionRole}"
INFRA_ROLE_NAME="${INFRA_ROLE_NAME:-ecsInfrastructureRoleForExpressServices}"

MIN_TASK_COUNT="${MIN_TASK_COUNT:-1}"
MAX_TASK_COUNT="${MAX_TASK_COUNT:-4}"
AUTO_SCALING_METRIC="${AUTO_SCALING_METRIC:-AVERAGE_CPU}"
AUTO_SCALING_TARGET_VALUE="${AUTO_SCALING_TARGET_VALUE:-60}"
LB_CPU_OVERRIDE="${LB_CPU_OVERRIDE:-}"
LB_MEMORY_OVERRIDE="${LB_MEMORY_OVERRIDE:-}"
BACKEND_CPU_OVERRIDE="${BACKEND_CPU_OVERRIDE:-}"
BACKEND_MEMORY_OVERRIDE="${BACKEND_MEMORY_OVERRIDE:-}"

AWS_ARGS=(--region "${AWS_REGION}" --no-cli-pager)
if [[ -n "${AWS_PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${AWS_PROFILE}")
fi

aws_cli() {
  "${AWS_BIN}" "${AWS_ARGS[@]}" "$@"
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

app_runner_value() {
  local service_arn="$1"
  local query="$2"
  aws_cli apprunner describe-service --service-arn "${service_arn}" --query "${query}" --output text
}

ensure_cluster_exists() {
  local cluster_name="${ECS_CLUSTER##*/}"
  local status

  status="$(aws_cli ecs describe-clusters --clusters "${ECS_CLUSTER}" --query 'clusters[0].status' --output text 2>/dev/null || true)"
  if [[ -z "${status}" || "${status}" == "None" ]]; then
    aws_cli ecs create-cluster --cluster-name "${cluster_name}" >/dev/null
    ECS_CLUSTER="${cluster_name}"
  fi

  aws_cli ecs put-cluster-capacity-providers \
    --cluster "${ECS_CLUSTER}" \
    --capacity-providers FARGATE FARGATE_SPOT \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1,base=1 >/dev/null
}

ensure_role() {
  local role_name="$1"
  local trust_service="$2"
  local policy_arn="$3"
  local trust_file

  if aws_cli iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    return 0
  fi

  trust_file="$(mktemp)"
  cat >"${trust_file}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "${trust_service}"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

  aws_cli iam create-role --role-name "${role_name}" --assume-role-policy-document "file://${trust_file}" >/dev/null
  aws_cli iam attach-role-policy --role-name "${role_name}" --policy-arn "${policy_arn}" >/dev/null
  rm -f "${trust_file}"
  sleep 12
}

ecs_service_arn_by_name() {
  local service_name="$1"
  local service_arns
  local candidate

  service_arns="$(aws_cli ecs list-services --cluster "${ECS_CLUSTER}" --query 'serviceArns' --output text 2>/dev/null || true)"
  for candidate in ${service_arns}; do
    if [[ "${candidate##*/}" != "${service_name}" ]]; then
      continue
    fi
    if aws_cli ecs describe-express-gateway-service --service-arn "${candidate}" >/dev/null 2>&1; then
      printf '%s' "${candidate}"
      return 0
    fi
  done

  return 1
}

env_pair_json() {
  local name="$1"
  local value="$2"
  printf '{"name":"%s","value":"%s"}' "$(json_escape "${name}")" "$(json_escape "${value}")"
}

build_env_json() {
  local mode="$1"
  local backend_name="$2"
  local backends="$3"
  local strategy="$4"
  local proxy_prefix="$5"
  local health_path="$6"
  local enable_frontend="$7"
  local entries=()

  entries+=("$(env_pair_json MODE "${mode}")")
  if [[ -n "${backend_name}" && "${backend_name}" != "None" ]]; then
    entries+=("$(env_pair_json BACKEND_NAME "${backend_name}")")
  fi
  if [[ -n "${backends}" && "${backends}" != "None" ]]; then
    entries+=("$(env_pair_json BACKENDS "${backends}")")
  fi
  if [[ -n "${strategy}" && "${strategy}" != "None" ]]; then
    entries+=("$(env_pair_json STRATEGY "${strategy}")")
  fi
  if [[ -n "${proxy_prefix}" && "${proxy_prefix}" != "None" ]]; then
    entries+=("$(env_pair_json PROXY_PREFIX "${proxy_prefix}")")
  fi
  if [[ -n "${health_path}" && "${health_path}" != "None" ]]; then
    entries+=("$(env_pair_json HEALTH_PATH "${health_path}")")
  fi
  if [[ -n "${enable_frontend}" && "${enable_frontend}" != "None" ]]; then
    entries+=("$(env_pair_json ENABLE_FRONTEND "${enable_frontend}")")
  fi

  local joined=""
  local entry
  for entry in "${entries[@]}"; do
    if [[ -n "${joined}" ]]; then
      joined+=","
    fi
    joined+="${entry}"
  done

  printf '[%s]' "${joined}"
}

wait_express_active() {
  local service_arn="$1"
  local service_name="$2"
  local status=""
  local reason=""

  for _ in $(seq 1 120); do
    status="$(aws_cli ecs describe-express-gateway-service --service-arn "${service_arn}" --query 'service.status.statusCode' --output text)"
    case "${status}" in
      ACTIVE)
        return 0
        ;;
      FAILED|DELETE_FAILED|INACTIVE)
        reason="$(aws_cli ecs describe-express-gateway-service --service-arn "${service_arn}" --query 'service.status.statusReason' --output text)"
        echo "Express service ${service_name} failed with status ${status}: ${reason}" >&2
        return 1
        ;;
      *)
        sleep 10
        ;;
    esac
  done

  echo "Timed out waiting for ECS Express service ${service_name} to become ACTIVE." >&2
  return 1
}

express_endpoint() {
  local service_arn="$1"
  aws_cli ecs describe-express-gateway-service --service-arn "${service_arn}" --query 'service.activeConfigurations[0].ingressPaths[0].endpoint' --output text
}

normalize_https_url() {
  local value="$1"
  if [[ "${value}" == http://* || "${value}" == https://* ]]; then
    printf '%s' "${value}"
    return 0
  fi
  printf 'https://%s' "${value}"
}

upsert_express_service() {
  local service_name="$1"
  local image_uri="$2"
  local port="$3"
  local cpu="$4"
  local memory="$5"
  local service_health_check_path="$6"
  local env_json="$7"
  local service_arn=""
  local payload_file

  if service_arn="$(ecs_service_arn_by_name "${service_name}")"; then
    payload_file="$(mktemp)"
    cat >"${payload_file}" <<JSON
{
  "serviceArn": "$(json_escape "${service_arn}")",
  "executionRoleArn": "$(json_escape "${EXECUTION_ROLE_ARN}")",
  "healthCheckPath": "$(json_escape "${service_health_check_path}")",
  "primaryContainer": {
    "image": "$(json_escape "${image_uri}")",
    "containerPort": ${port},
    "environment": ${env_json}
  },
  "cpu": "$(json_escape "${cpu}")",
  "memory": "$(json_escape "${memory}")",
  "scalingTarget": {
    "minTaskCount": ${MIN_TASK_COUNT},
    "maxTaskCount": ${MAX_TASK_COUNT},
    "autoScalingMetric": "$(json_escape "${AUTO_SCALING_METRIC}")",
    "autoScalingTargetValue": ${AUTO_SCALING_TARGET_VALUE}
  }
}
JSON
    aws_cli ecs update-express-gateway-service --cli-input-json "file://${payload_file}" >/dev/null
    rm -f "${payload_file}"
    printf '%s' "${service_arn}"
    return 0
  fi

  payload_file="$(mktemp)"
  cat >"${payload_file}" <<JSON
{
  "serviceName": "$(json_escape "${service_name}")",
  "cluster": "$(json_escape "${ECS_CLUSTER}")",
  "executionRoleArn": "$(json_escape "${EXECUTION_ROLE_ARN}")",
  "infrastructureRoleArn": "$(json_escape "${INFRA_ROLE_ARN}")",
  "healthCheckPath": "$(json_escape "${service_health_check_path}")",
  "primaryContainer": {
    "image": "$(json_escape "${image_uri}")",
    "containerPort": ${port},
    "environment": ${env_json}
  },
  "cpu": "$(json_escape "${cpu}")",
  "memory": "$(json_escape "${memory}")",
  "scalingTarget": {
    "minTaskCount": ${MIN_TASK_COUNT},
    "maxTaskCount": ${MAX_TASK_COUNT},
    "autoScalingMetric": "$(json_escape "${AUTO_SCALING_METRIC}")",
    "autoScalingTargetValue": ${AUTO_SCALING_TARGET_VALUE}
  },
  "tags": [
    {
      "key": "migrated-from",
      "value": "app-runner"
    },
    {
      "key": "app",
      "value": "$(json_escape "${service_name}")"
    }
  ]
}
JSON
  service_arn="$(aws_cli ecs create-express-gateway-service --cli-input-json "file://${payload_file}" --query 'service.serviceArn' --output text)"
  rm -f "${payload_file}"
  printf '%s' "${service_arn}"
}

collect_service_config() {
  local service_arn="$1"

  SERVICE_NAME="$(app_runner_value "${service_arn}" 'Service.ServiceName')"
  IMAGE_URI="$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageIdentifier')"
  PORT="$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.Port')"
  CPU="$(app_runner_value "${service_arn}" 'Service.InstanceConfiguration.Cpu')"
  MEMORY="$(app_runner_value "${service_arn}" 'Service.InstanceConfiguration.Memory')"
  SERVICE_HEALTH_CHECK_PATH="$(app_runner_value "${service_arn}" 'Service.HealthCheckConfiguration.Path')"
  MODE_VALUE="$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.MODE')"
  BACKEND_NAME_VALUE="$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.BACKEND_NAME')"
  BACKENDS_VALUE="$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.BACKENDS')"
  STRATEGY_VALUE="$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.STRATEGY')"
  PROXY_PREFIX_VALUE="$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.PROXY_PREFIX')"
  HEALTH_PATH_VALUE="$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.HEALTH_PATH')"
  ENABLE_FRONTEND_VALUE="$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.ENABLE_FRONTEND')"
}

apply_compute_override() {
  local service_name="$1"
  case "${service_name}" in
    mini-load-balancer)
      if [[ -n "${LB_CPU_OVERRIDE}" ]]; then
        CPU="${LB_CPU_OVERRIDE}"
      fi
      if [[ -n "${LB_MEMORY_OVERRIDE}" ]]; then
        MEMORY="${LB_MEMORY_OVERRIDE}"
      fi
      ;;
    mini-load-balancer-backend-a|mini-load-balancer-backend-b)
      if [[ -n "${BACKEND_CPU_OVERRIDE}" ]]; then
        CPU="${BACKEND_CPU_OVERRIDE}"
      fi
      if [[ -n "${BACKEND_MEMORY_OVERRIDE}" ]]; then
        MEMORY="${BACKEND_MEMORY_OVERRIDE}"
      fi
      ;;
  esac
}

echo "[1/7] Validating AWS access and ECS cluster..."
aws_cli sts get-caller-identity >/dev/null
ensure_cluster_exists

echo "[2/7] Ensuring required IAM roles exist..."
ensure_role "${EXECUTION_ROLE_NAME}" "ecs-tasks.amazonaws.com" "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
ensure_role "${INFRA_ROLE_NAME}" "ecs.amazonaws.com" "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices"
EXECUTION_ROLE_ARN="$(aws_cli iam get-role --role-name "${EXECUTION_ROLE_NAME}" --query 'Role.Arn' --output text)"
INFRA_ROLE_ARN="$(aws_cli iam get-role --role-name "${INFRA_ROLE_NAME}" --query 'Role.Arn' --output text)"

echo "[3/7] Migrating backend A from App Runner to ECS Express..."
collect_service_config "${BACKEND_A_APP_RUNNER_ARN}"
apply_compute_override "${SERVICE_NAME}"
BACKEND_A_ENV_JSON="$(build_env_json "${MODE_VALUE}" "${BACKEND_NAME_VALUE}" "" "${STRATEGY_VALUE}" "${PROXY_PREFIX_VALUE}" "${HEALTH_PATH_VALUE}" "${ENABLE_FRONTEND_VALUE}")"
BACKEND_A_ECS_ARN="$(upsert_express_service "${SERVICE_NAME}" "${IMAGE_URI}" "${PORT}" "${CPU}" "${MEMORY}" "${SERVICE_HEALTH_CHECK_PATH}" "${BACKEND_A_ENV_JSON}")"
wait_express_active "${BACKEND_A_ECS_ARN}" "${SERVICE_NAME}"
BACKEND_A_ECS_ENDPOINT="$(express_endpoint "${BACKEND_A_ECS_ARN}")"

echo "[4/7] Migrating backend B from App Runner to ECS Express..."
collect_service_config "${BACKEND_B_APP_RUNNER_ARN}"
apply_compute_override "${SERVICE_NAME}"
BACKEND_B_ENV_JSON="$(build_env_json "${MODE_VALUE}" "${BACKEND_NAME_VALUE}" "" "${STRATEGY_VALUE}" "${PROXY_PREFIX_VALUE}" "${HEALTH_PATH_VALUE}" "${ENABLE_FRONTEND_VALUE}")"
BACKEND_B_ECS_ARN="$(upsert_express_service "${SERVICE_NAME}" "${IMAGE_URI}" "${PORT}" "${CPU}" "${MEMORY}" "${SERVICE_HEALTH_CHECK_PATH}" "${BACKEND_B_ENV_JSON}")"
wait_express_active "${BACKEND_B_ECS_ARN}" "${SERVICE_NAME}"
BACKEND_B_ECS_ENDPOINT="$(express_endpoint "${BACKEND_B_ECS_ARN}")"

echo "[5/7] Migrating load balancer from App Runner to ECS Express..."
collect_service_config "${LB_APP_RUNNER_ARN}"
apply_compute_override "${SERVICE_NAME}"
LB_BACKENDS_VALUE="$(normalize_https_url "${BACKEND_A_ECS_ENDPOINT}"),$(normalize_https_url "${BACKEND_B_ECS_ENDPOINT}")"
LB_ENV_JSON="$(build_env_json "${MODE_VALUE}" "${BACKEND_NAME_VALUE}" "${LB_BACKENDS_VALUE}" "${STRATEGY_VALUE}" "${PROXY_PREFIX_VALUE}" "${HEALTH_PATH_VALUE}" "${ENABLE_FRONTEND_VALUE}")"
LB_ECS_ARN="$(upsert_express_service "${SERVICE_NAME}" "${IMAGE_URI}" "${PORT}" "${CPU}" "${MEMORY}" "${SERVICE_HEALTH_CHECK_PATH}" "${LB_ENV_JSON}")"
wait_express_active "${LB_ECS_ARN}" "${SERVICE_NAME}"
LB_ECS_ENDPOINT="$(express_endpoint "${LB_ECS_ARN}")"

echo "[6/7] Fetching current App Runner URLs for rollback reference..."
BACKEND_A_APP_RUNNER_URL="$(app_runner_value "${BACKEND_A_APP_RUNNER_ARN}" 'Service.ServiceUrl')"
BACKEND_B_APP_RUNNER_URL="$(app_runner_value "${BACKEND_B_APP_RUNNER_ARN}" 'Service.ServiceUrl')"
LB_APP_RUNNER_URL="$(app_runner_value "${LB_APP_RUNNER_ARN}" 'Service.ServiceUrl')"

echo "[7/7] Migration resources are ready."
echo
echo "ECS Express services"
echo "  - backend-a: $(normalize_https_url "${BACKEND_A_ECS_ENDPOINT}")"
echo "  - backend-b: $(normalize_https_url "${BACKEND_B_ECS_ENDPOINT}")"
echo "  - load-balancer: $(normalize_https_url "${LB_ECS_ENDPOINT}")"
echo
echo "App Runner rollback endpoints"
echo "  - backend-a: https://${BACKEND_A_APP_RUNNER_URL}"
echo "  - backend-b: https://${BACKEND_B_APP_RUNNER_URL}"
echo "  - load-balancer: https://${LB_APP_RUNNER_URL}"
echo
echo "Suggested validation URLs"
echo "  - $(normalize_https_url "${LB_ECS_ENDPOINT}")/"
echo "  - $(normalize_https_url "${LB_ECS_ENDPOINT}")/healthz"
echo "  - $(normalize_https_url "${LB_ECS_ENDPOINT}")/admin/backends"
echo "  - $(normalize_https_url "${LB_ECS_ENDPOINT}")/proxy/whoami"
