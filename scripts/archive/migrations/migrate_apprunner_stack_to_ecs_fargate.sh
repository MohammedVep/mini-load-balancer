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

BACKEND_A_APP_RUNNER_ARN="${BACKEND_A_APP_RUNNER_ARN:-arn:aws:apprunner:us-east-1:194191749520:service/mini-load-balancer-backend-a/f967a656457845f6a33f9aa3ad85199e}"
BACKEND_B_APP_RUNNER_ARN="${BACKEND_B_APP_RUNNER_ARN:-arn:aws:apprunner:us-east-1:194191749520:service/mini-load-balancer-backend-b/845e84ec34eb4b149fe55c45be2dfa56}"
LB_APP_RUNNER_ARN="${LB_APP_RUNNER_ARN:-arn:aws:apprunner:us-east-1:194191749520:service/mini-load-balancer/3a9e9bac11a3471d90fbe874379f609e}"

ECS_CLUSTER="${ECS_CLUSTER:-mini-load-balancer-fargate}"
VPC_ID="${VPC_ID:-vpc-01b8820eda6e42933}"
SUBNET_IDS="${SUBNET_IDS:-subnet-0a9f708e20d77e8de,subnet-017b80d77d8471856}"
NAMESPACE_ID="${NAMESPACE_ID:-ns-ds56tjw5q5vn2m4q}"
NAMESPACE_NAME="${NAMESPACE_NAME:-np-prod.internal}"

LB_ECS_SERVICE_NAME="${LB_ECS_SERVICE_NAME:-mini-load-balancer-ecs}"
BACKEND_A_ECS_SERVICE_NAME="${BACKEND_A_ECS_SERVICE_NAME:-mini-load-balancer-backend-a-ecs}"
BACKEND_B_ECS_SERVICE_NAME="${BACKEND_B_ECS_SERVICE_NAME:-mini-load-balancer-backend-b-ecs}"

BACKEND_A_DISCOVERY_NAME="${BACKEND_A_DISCOVERY_NAME:-mini-load-balancer-backend-a-ecs}"
BACKEND_B_DISCOVERY_NAME="${BACKEND_B_DISCOVERY_NAME:-mini-load-balancer-backend-b-ecs}"

ALB_NAME="${ALB_NAME:-mini-load-balancer-ecs-alb}"
TARGET_GROUP_NAME="${TARGET_GROUP_NAME:-mini-load-balancer-ecs-tg}"
ALB_SECURITY_GROUP_NAME="${ALB_SECURITY_GROUP_NAME:-mini-load-balancer-ecs-alb-sg}"
LB_SECURITY_GROUP_NAME="${LB_SECURITY_GROUP_NAME:-mini-load-balancer-ecs-lb-sg}"
BACKEND_SECURITY_GROUP_NAME="${BACKEND_SECURITY_GROUP_NAME:-mini-load-balancer-ecs-backend-sg}"

EXECUTION_ROLE_NAME="${EXECUTION_ROLE_NAME:-ecsTaskExecutionRole}"

LB_DESIRED_COUNT="${LB_DESIRED_COUNT:-1}"
BACKEND_A_DESIRED_COUNT="${BACKEND_A_DESIRED_COUNT:-1}"
BACKEND_B_DESIRED_COUNT="${BACKEND_B_DESIRED_COUNT:-1}"
ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-ENABLED}"
LISTENER_PORT="${LISTENER_PORT:-80}"
CONTAINER_NAME="${CONTAINER_NAME:-app}"
CONTAINER_PORT="${CONTAINER_PORT:-8080}"

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

trim_none() {
  local value="${1:-}"
  if [[ "${value}" == "None" || "${value}" == "null" ]]; then
    printf ''
    return 0
  fi
  printf '%s' "${value}"
}

app_runner_value() {
  local service_arn="$1"
  local query="$2"
  aws_cli apprunner describe-service --service-arn "${service_arn}" --query "${query}" --output text
}

ensure_cluster() {
  local status
  status="$(aws_cli ecs describe-clusters --clusters "${ECS_CLUSTER}" --query 'clusters[0].status' --output text 2>/dev/null || true)"
  if [[ -z "${status}" || "${status}" == "None" ]]; then
    aws_cli ecs create-cluster \
      --cluster-name "${ECS_CLUSTER}" \
      --settings name=containerInsights,value=enabled >/dev/null
  fi
}

ensure_role() {
  local role_name="$1"
  if aws_cli iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    return 0
  fi

  local trust_file
  trust_file="$(mktemp)"
  cat >"${trust_file}" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

  aws_cli iam create-role \
    --role-name "${role_name}" \
    --assume-role-policy-document "file://${trust_file}" >/dev/null
  aws_cli iam attach-role-policy \
    --role-name "${role_name}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null
  rm -f "${trust_file}"
  sleep 10
}

ensure_log_group() {
  local log_group="$1"
  if ! aws_cli logs describe-log-groups --log-group-name-prefix "${log_group}" --query "logGroups[?logGroupName=='${log_group}'].logGroupName | [0]" --output text | grep -qx "${log_group}"; then
    aws_cli logs create-log-group --log-group-name "${log_group}" >/dev/null
  fi
  aws_cli logs put-retention-policy --log-group-name "${log_group}" --retention-in-days 14 >/dev/null
}

security_group_id_by_name() {
  local group_name="$1"
  aws_cli ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${group_name}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true
}

ensure_security_group() {
  local group_name="$1"
  local description="$2"
  local group_id

  group_id="$(security_group_id_by_name "${group_name}")"
  if [[ -n "${group_id}" && "${group_id}" != "None" ]]; then
    printf '%s' "${group_id}"
    return 0
  fi

  aws_cli ec2 create-security-group \
    --group-name "${group_name}" \
    --description "${description}" \
    --vpc-id "${VPC_ID}" \
    --query 'GroupId' --output text
}

ensure_cidr_ingress() {
  local group_id="$1"
  local port="$2"
  local cidr="$3"

  aws_cli ec2 authorize-security-group-ingress \
    --group-id "${group_id}" \
    --ip-permissions "IpProtocol=tcp,FromPort=${port},ToPort=${port},IpRanges=[{CidrIp=${cidr},Description=public-http}]" >/dev/null 2>&1 || true
}

ensure_group_ingress() {
  local group_id="$1"
  local source_group_id="$2"
  local port="$3"
  local description="$4"

  aws_cli ec2 authorize-security-group-ingress \
    --group-id "${group_id}" \
    --ip-permissions "IpProtocol=tcp,FromPort=${port},ToPort=${port},UserIdGroupPairs=[{GroupId=${source_group_id},Description=${description}}]" >/dev/null 2>&1 || true
}

cloud_map_service_arn_by_name() {
  local service_name="$1"
  aws_cli servicediscovery list-services \
    --filters "Name=NAMESPACE_ID,Values=${NAMESPACE_ID},Condition=EQ" \
    --query "Services[?Name=='${service_name}'].Arn | [0]" \
    --output text
}

ensure_cloud_map_service() {
  local service_name="$1"
  local arn

  arn="$(cloud_map_service_arn_by_name "${service_name}")"
  if [[ -n "${arn}" && "${arn}" != "None" ]]; then
    printf '%s' "${arn}"
    return 0
  fi

  aws_cli servicediscovery create-service \
    --name "${service_name}" \
    --namespace-id "${NAMESPACE_ID}" \
    --dns-config "NamespaceId=${NAMESPACE_ID},RoutingPolicy=MULTIVALUE,DnsRecords=[{Type=A,TTL=10}]" \
    --health-check-custom-config FailureThreshold=1 \
    --query 'Service.Arn' --output text
}

alb_arn_by_name() {
  local name="$1"
  aws_cli elbv2 describe-load-balancers --names "${name}" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true
}

ensure_alb() {
  local alb_name="$1"
  local alb_sg_id="$2"
  local alb_arn

  alb_arn="$(alb_arn_by_name "${alb_name}")"
  if [[ -n "${alb_arn}" && "${alb_arn}" != "None" ]]; then
    printf '%s' "${alb_arn}"
    return 0
  fi

  aws_cli elbv2 create-load-balancer \
    --name "${alb_name}" \
    --type application \
    --scheme internet-facing \
    --security-groups "${alb_sg_id}" \
    --subnets ${SUBNET_IDS//,/ } \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text
}

target_group_arn_by_name() {
  local name="$1"
  aws_cli elbv2 describe-target-groups --names "${name}" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true
}

ensure_target_group() {
  local tg_name="$1"
  local tg_arn

  tg_arn="$(target_group_arn_by_name "${tg_name}")"
  if [[ -n "${tg_arn}" && "${tg_arn}" != "None" ]]; then
    aws_cli elbv2 modify-target-group \
      --target-group-arn "${tg_arn}" \
      --health-check-path /healthz \
      --health-check-protocol HTTP \
      --health-check-port traffic-port \
      --health-check-interval-seconds 10 \
      --health-check-timeout-seconds 5 \
      --healthy-threshold-count 2 \
      --unhealthy-threshold-count 3 >/dev/null
    printf '%s' "${tg_arn}"
    return 0
  fi

  aws_cli elbv2 create-target-group \
    --name "${tg_name}" \
    --protocol HTTP \
    --port "${CONTAINER_PORT}" \
    --target-type ip \
    --vpc-id "${VPC_ID}" \
    --health-check-path /healthz \
    --health-check-protocol HTTP \
    --health-check-port traffic-port \
    --health-check-interval-seconds 10 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' --output text
}

ensure_listener() {
  local alb_arn="$1"
  local target_group_arn="$2"
  local listener_arn

  listener_arn="$(aws_cli elbv2 describe-listeners --load-balancer-arn "${alb_arn}" --query "Listeners[?Port==\`${LISTENER_PORT}\`].ListenerArn | [0]" --output text 2>/dev/null || true)"
  if [[ -n "${listener_arn}" && "${listener_arn}" != "None" ]]; then
    aws_cli elbv2 modify-listener \
      --listener-arn "${listener_arn}" \
      --default-actions "Type=forward,TargetGroupArn=${target_group_arn}" >/dev/null
    printf '%s' "${listener_arn}"
    return 0
  fi

  aws_cli elbv2 create-listener \
    --load-balancer-arn "${alb_arn}" \
    --protocol HTTP \
    --port "${LISTENER_PORT}" \
    --default-actions "Type=forward,TargetGroupArn=${target_group_arn}" \
    --query 'Listeners[0].ListenerArn' --output text
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
  if [[ -n "${backend_name}" ]]; then
    entries+=("$(env_pair_json BACKEND_NAME "${backend_name}")")
  fi
  if [[ -n "${backends}" ]]; then
    entries+=("$(env_pair_json BACKENDS "${backends}")")
  fi
  if [[ -n "${strategy}" ]]; then
    entries+=("$(env_pair_json STRATEGY "${strategy}")")
  fi
  if [[ -n "${proxy_prefix}" ]]; then
    entries+=("$(env_pair_json PROXY_PREFIX "${proxy_prefix}")")
  fi
  if [[ -n "${health_path}" ]]; then
    entries+=("$(env_pair_json HEALTH_PATH "${health_path}")")
  fi
  if [[ -n "${enable_frontend}" ]]; then
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

register_task_definition() {
  local family="$1"
  local image_uri="$2"
  local cpu="$3"
  local memory="$4"
  local port="$5"
  local log_group="$6"
  local env_json="$7"
  local payload_file task_def_arn

  payload_file="$(mktemp)"
  cat >"${payload_file}" <<JSON
{
  "family": "$(json_escape "${family}")",
  "executionRoleArn": "$(json_escape "${EXECUTION_ROLE_ARN}")",
  "networkMode": "awsvpc",
  "runtimePlatform": {
    "operatingSystemFamily": "LINUX",
    "cpuArchitecture": "X86_64"
  },
  "requiresCompatibilities": [
    "FARGATE"
  ],
  "cpu": "$(json_escape "${cpu}")",
  "memory": "$(json_escape "${memory}")",
  "containerDefinitions": [
    {
      "name": "$(json_escape "${CONTAINER_NAME}")",
      "image": "$(json_escape "${image_uri}")",
      "essential": true,
      "portMappings": [
        {
          "containerPort": ${port},
          "hostPort": ${port},
          "protocol": "tcp"
        }
      ],
      "environment": ${env_json},
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$(json_escape "${log_group}")",
          "awslogs-region": "$(json_escape "${AWS_REGION}")",
          "awslogs-stream-prefix": "$(json_escape "${family}")"
        }
      }
    }
  ]
}
JSON

  task_def_arn="$(aws_cli ecs register-task-definition --cli-input-json "file://${payload_file}" --query 'taskDefinition.taskDefinitionArn' --output text)"
  rm -f "${payload_file}"
  printf '%s' "${task_def_arn}"
}

ecs_service_arn_by_name() {
  local service_name="$1"
  aws_cli ecs describe-services \
    --cluster "${ECS_CLUSTER}" \
    --services "${service_name}" \
    --query 'services[0].serviceArn' --output text 2>/dev/null || true
}

upsert_backend_service() {
  local service_name="$1"
  local task_definition_arn="$2"
  local desired_count="$3"
  local security_group_id="$4"
  local registry_arn="$5"
  local service_arn

  service_arn="$(ecs_service_arn_by_name "${service_name}")"
  if [[ -n "${service_arn}" && "${service_arn}" != "None" ]]; then
    aws_cli ecs update-service \
      --cluster "${ECS_CLUSTER}" \
      --service "${service_name}" \
      --task-definition "${task_definition_arn}" \
      --desired-count "${desired_count}" \
      --service-registries "registryArn=${registry_arn}" \
      --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${security_group_id}],assignPublicIp=${ASSIGN_PUBLIC_IP}}" \
      --force-new-deployment >/dev/null
    printf '%s' "${service_arn}"
    return 0
  fi

  aws_cli ecs create-service \
    --cluster "${ECS_CLUSTER}" \
    --service-name "${service_name}" \
    --launch-type FARGATE \
    --task-definition "${task_definition_arn}" \
    --desired-count "${desired_count}" \
    --service-registries "registryArn=${registry_arn}" \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${security_group_id}],assignPublicIp=${ASSIGN_PUBLIC_IP}}" \
    --query 'service.serviceArn' --output text
}

upsert_lb_service() {
  local service_name="$1"
  local task_definition_arn="$2"
  local desired_count="$3"
  local security_group_id="$4"
  local target_group_arn="$5"
  local service_arn

  service_arn="$(ecs_service_arn_by_name "${service_name}")"
  if [[ -n "${service_arn}" && "${service_arn}" != "None" ]]; then
    aws_cli ecs update-service \
      --cluster "${ECS_CLUSTER}" \
      --service "${service_name}" \
      --task-definition "${task_definition_arn}" \
      --desired-count "${desired_count}" \
      --load-balancers "targetGroupArn=${target_group_arn},containerName=${CONTAINER_NAME},containerPort=${CONTAINER_PORT}" \
      --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${security_group_id}],assignPublicIp=${ASSIGN_PUBLIC_IP}}" \
      --force-new-deployment >/dev/null
    printf '%s' "${service_arn}"
    return 0
  fi

  aws_cli ecs create-service \
    --cluster "${ECS_CLUSTER}" \
    --service-name "${service_name}" \
    --launch-type FARGATE \
    --task-definition "${task_definition_arn}" \
    --desired-count "${desired_count}" \
    --health-check-grace-period-seconds 60 \
    --load-balancers "targetGroupArn=${target_group_arn},containerName=${CONTAINER_NAME},containerPort=${CONTAINER_PORT}" \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${security_group_id}],assignPublicIp=${ASSIGN_PUBLIC_IP}}" \
    --query 'service.serviceArn' --output text
}

wait_service_stable() {
  local service_name="$1"
  aws_cli ecs wait services-stable --cluster "${ECS_CLUSTER}" --services "${service_name}"
}

collect_service_config() {
  local service_arn="$1"

  SERVICE_NAME="$(trim_none "$(app_runner_value "${service_arn}" 'Service.ServiceName')")"
  IMAGE_URI="$(trim_none "$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageIdentifier')")"
  PORT="$(trim_none "$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.Port')")"
  CPU="$(trim_none "$(app_runner_value "${service_arn}" 'Service.InstanceConfiguration.Cpu')")"
  MEMORY="$(trim_none "$(app_runner_value "${service_arn}" 'Service.InstanceConfiguration.Memory')")"
  MODE_VALUE="$(trim_none "$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.MODE')")"
  BACKEND_NAME_VALUE="$(trim_none "$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.BACKEND_NAME')")"
  BACKENDS_VALUE="$(trim_none "$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.BACKENDS')")"
  STRATEGY_VALUE="$(trim_none "$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.STRATEGY')")"
  PROXY_PREFIX_VALUE="$(trim_none "$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.PROXY_PREFIX')")"
  HEALTH_PATH_VALUE="$(trim_none "$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.HEALTH_PATH')")"
  ENABLE_FRONTEND_VALUE="$(trim_none "$(app_runner_value "${service_arn}" 'Service.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables.ENABLE_FRONTEND')")"
}

alb_dns_name() {
  local alb_arn="$1"
  aws_cli elbv2 describe-load-balancers --load-balancer-arns "${alb_arn}" --query 'LoadBalancers[0].DNSName' --output text
}

echo "[1/9] Validating AWS access and base infrastructure..."
aws_cli sts get-caller-identity >/dev/null
ensure_cluster
ensure_role "${EXECUTION_ROLE_NAME}"
EXECUTION_ROLE_ARN="$(aws_cli iam get-role --role-name "${EXECUTION_ROLE_NAME}" --query 'Role.Arn' --output text)"

echo "[2/9] Ensuring security groups..."
ALB_SECURITY_GROUP_ID="$(ensure_security_group "${ALB_SECURITY_GROUP_NAME}" "Security group for mini load balancer ECS ALB")"
LB_SECURITY_GROUP_ID="$(ensure_security_group "${LB_SECURITY_GROUP_NAME}" "Security group for mini load balancer ECS tasks")"
BACKEND_SECURITY_GROUP_ID="$(ensure_security_group "${BACKEND_SECURITY_GROUP_NAME}" "Security group for mini load balancer ECS backends")"
ensure_cidr_ingress "${ALB_SECURITY_GROUP_ID}" "${LISTENER_PORT}" "0.0.0.0/0"
ensure_group_ingress "${LB_SECURITY_GROUP_ID}" "${ALB_SECURITY_GROUP_ID}" "${CONTAINER_PORT}" "alb-to-lb"
ensure_group_ingress "${BACKEND_SECURITY_GROUP_ID}" "${LB_SECURITY_GROUP_ID}" "${CONTAINER_PORT}" "lb-to-backends"

echo "[3/9] Ensuring Cloud Map services..."
BACKEND_A_REGISTRY_ARN="$(ensure_cloud_map_service "${BACKEND_A_DISCOVERY_NAME}")"
BACKEND_B_REGISTRY_ARN="$(ensure_cloud_map_service "${BACKEND_B_DISCOVERY_NAME}")"

echo "[4/9] Ensuring public ALB and target group..."
ALB_ARN="$(ensure_alb "${ALB_NAME}" "${ALB_SECURITY_GROUP_ID}")"
aws_cli elbv2 wait load-balancer-available --load-balancer-arns "${ALB_ARN}"
TARGET_GROUP_ARN="$(ensure_target_group "${TARGET_GROUP_NAME}")"
ensure_listener "${ALB_ARN}" "${TARGET_GROUP_ARN}" >/dev/null

echo "[5/9] Registering backend task definitions from live App Runner images..."
collect_service_config "${BACKEND_A_APP_RUNNER_ARN}"
ensure_log_group "/ecs/${BACKEND_A_ECS_SERVICE_NAME}"
BACKEND_A_ENV_JSON="$(build_env_json "${MODE_VALUE}" "${BACKEND_NAME_VALUE}" "" "${STRATEGY_VALUE}" "${PROXY_PREFIX_VALUE}" "${HEALTH_PATH_VALUE}" "${ENABLE_FRONTEND_VALUE}")"
BACKEND_A_TASK_DEF_ARN="$(register_task_definition "${BACKEND_A_ECS_SERVICE_NAME}" "${IMAGE_URI}" "${CPU}" "${MEMORY}" "${PORT:-${CONTAINER_PORT}}" "/ecs/${BACKEND_A_ECS_SERVICE_NAME}" "${BACKEND_A_ENV_JSON}")"

collect_service_config "${BACKEND_B_APP_RUNNER_ARN}"
ensure_log_group "/ecs/${BACKEND_B_ECS_SERVICE_NAME}"
BACKEND_B_ENV_JSON="$(build_env_json "${MODE_VALUE}" "${BACKEND_NAME_VALUE}" "" "${STRATEGY_VALUE}" "${PROXY_PREFIX_VALUE}" "${HEALTH_PATH_VALUE}" "${ENABLE_FRONTEND_VALUE}")"
BACKEND_B_TASK_DEF_ARN="$(register_task_definition "${BACKEND_B_ECS_SERVICE_NAME}" "${IMAGE_URI}" "${CPU}" "${MEMORY}" "${PORT:-${CONTAINER_PORT}}" "/ecs/${BACKEND_B_ECS_SERVICE_NAME}" "${BACKEND_B_ENV_JSON}")"

echo "[6/9] Deploying backend services..."
upsert_backend_service "${BACKEND_A_ECS_SERVICE_NAME}" "${BACKEND_A_TASK_DEF_ARN}" "${BACKEND_A_DESIRED_COUNT}" "${BACKEND_SECURITY_GROUP_ID}" "${BACKEND_A_REGISTRY_ARN}" >/dev/null
upsert_backend_service "${BACKEND_B_ECS_SERVICE_NAME}" "${BACKEND_B_TASK_DEF_ARN}" "${BACKEND_B_DESIRED_COUNT}" "${BACKEND_SECURITY_GROUP_ID}" "${BACKEND_B_REGISTRY_ARN}" >/dev/null
wait_service_stable "${BACKEND_A_ECS_SERVICE_NAME}"
wait_service_stable "${BACKEND_B_ECS_SERVICE_NAME}"

echo "[7/9] Registering load balancer task definition from live App Runner image..."
collect_service_config "${LB_APP_RUNNER_ARN}"
ensure_log_group "/ecs/${LB_ECS_SERVICE_NAME}"
INTERNAL_BACKENDS="http://${BACKEND_A_DISCOVERY_NAME}.${NAMESPACE_NAME}:${CONTAINER_PORT},http://${BACKEND_B_DISCOVERY_NAME}.${NAMESPACE_NAME}:${CONTAINER_PORT}"
LB_ENV_JSON="$(build_env_json "${MODE_VALUE}" "${BACKEND_NAME_VALUE}" "${INTERNAL_BACKENDS}" "${STRATEGY_VALUE}" "${PROXY_PREFIX_VALUE}" "${HEALTH_PATH_VALUE}" "${ENABLE_FRONTEND_VALUE}")"
LB_TASK_DEF_ARN="$(register_task_definition "${LB_ECS_SERVICE_NAME}" "${IMAGE_URI}" "${CPU}" "${MEMORY}" "${PORT:-${CONTAINER_PORT}}" "/ecs/${LB_ECS_SERVICE_NAME}" "${LB_ENV_JSON}")"

echo "[8/9] Deploying load balancer service..."
upsert_lb_service "${LB_ECS_SERVICE_NAME}" "${LB_TASK_DEF_ARN}" "${LB_DESIRED_COUNT}" "${LB_SECURITY_GROUP_ID}" "${TARGET_GROUP_ARN}" >/dev/null
wait_service_stable "${LB_ECS_SERVICE_NAME}"

echo "[9/9] Collecting outputs..."
ALB_DNS_NAME="$(alb_dns_name "${ALB_ARN}")"
APP_RUNNER_URL="$(app_runner_value "${LB_APP_RUNNER_ARN}" 'Service.ServiceUrl')"

echo
echo "ECS/Fargate stack is deployed."
echo "  Cluster:          ${ECS_CLUSTER}"
echo "  Public ECS URL:   http://${ALB_DNS_NAME}"
echo "  App Runner URL:   https://${APP_RUNNER_URL}"
echo "  Backend A DNS:    http://${BACKEND_A_DISCOVERY_NAME}.${NAMESPACE_NAME}:${CONTAINER_PORT}"
echo "  Backend B DNS:    http://${BACKEND_B_DISCOVERY_NAME}.${NAMESPACE_NAME}:${CONTAINER_PORT}"
echo
echo "Suggested smoke tests"
echo "  - http://${ALB_DNS_NAME}/healthz"
echo "  - http://${ALB_DNS_NAME}/admin/backends"
echo "  - http://${ALB_DNS_NAME}/admin/strategy"
echo "  - http://${ALB_DNS_NAME}/ai/status"
echo "  - http://${ALB_DNS_NAME}/proxy/whoami"
