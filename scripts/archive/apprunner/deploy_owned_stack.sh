#!/usr/bin/env bash
set -euo pipefail

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required." >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required." >&2
  exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
LB_SERVICE_NAME="${LB_SERVICE_NAME:-mini-load-balancer}"
BACKEND_A_SERVICE_NAME="${BACKEND_A_SERVICE_NAME:-${LB_SERVICE_NAME}-backend-a}"
BACKEND_B_SERVICE_NAME="${BACKEND_B_SERVICE_NAME:-${LB_SERVICE_NAME}-backend-b}"
ECR_REPO="${ECR_REPO:-${LB_SERVICE_NAME}}"
ROLE_NAME="${ROLE_NAME:-${LB_SERVICE_NAME}-apprunner-ecr-role}"

LB_STRATEGY="${LB_STRATEGY:-least_connections}"
PROXY_PREFIX="${PROXY_PREFIX:-/proxy}"
HEALTH_PATH="${HEALTH_PATH:-/healthz}"

LB_CPU="${LB_CPU:-1024}"
LB_MEMORY="${LB_MEMORY:-2048}"
BACKEND_CPU="${BACKEND_CPU:-1024}"
BACKEND_MEMORY="${BACKEND_MEMORY:-2048}"

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

service_arn_by_name() {
  local name="$1"
  aws apprunner list-services --region "${AWS_REGION}" --query "ServiceSummaryList[?ServiceName=='${name}'].ServiceArn | [0]" --output text
}

wait_service_running() {
  local service_arn="$1"
  local label="$2"
  local status

  for _ in $(seq 1 120); do
    status="$(aws apprunner describe-service --region "${AWS_REGION}" --service-arn "${service_arn}" --query Service.Status --output text)"
    case "${status}" in
      RUNNING)
        return 0
        ;;
      CREATE_FAILED|DELETE_FAILED|OPERATION_FAILED)
        echo "${label} failed with status ${status}" >&2
        aws apprunner describe-service --region "${AWS_REGION}" --service-arn "${service_arn}" --output json >&2
        return 1
        ;;
      *)
        sleep 10
        ;;
    esac
  done

  echo "Timed out waiting for ${label} to reach RUNNING." >&2
  return 1
}

upsert_service() {
  local service_name="$1"
  local mode="$2"
  local backend_name="$3"
  local backends="$4"
  local strategy="$5"
  local proxy_prefix="$6"
  local health_path="$7"
  local enable_frontend="$8"
  local cpu="$9"
  local memory="${10}"
  local role_arn="${11}"
  local image_uri="${12}"

  local service_arn tmp_json
  service_arn="$(service_arn_by_name "${service_name}")"
  tmp_json="$(mktemp)"

  local esc_service_name esc_mode esc_backend_name esc_backends esc_strategy esc_proxy_prefix esc_health_path esc_enable_frontend esc_cpu esc_memory esc_role_arn esc_image_uri
  esc_service_name="$(json_escape "${service_name}")"
  esc_mode="$(json_escape "${mode}")"
  esc_backend_name="$(json_escape "${backend_name}")"
  esc_backends="$(json_escape "${backends}")"
  esc_strategy="$(json_escape "${strategy}")"
  esc_proxy_prefix="$(json_escape "${proxy_prefix}")"
  esc_health_path="$(json_escape "${health_path}")"
  esc_enable_frontend="$(json_escape "${enable_frontend}")"
  esc_cpu="$(json_escape "${cpu}")"
  esc_memory="$(json_escape "${memory}")"
  esc_role_arn="$(json_escape "${role_arn}")"
  esc_image_uri="$(json_escape "${image_uri}")"

  if [[ -z "${service_arn}" || "${service_arn}" == "None" ]]; then
    cat >"${tmp_json}" <<JSON
{
  "ServiceName": "${esc_service_name}",
  "SourceConfiguration": {
    "AuthenticationConfiguration": {
      "AccessRoleArn": "${esc_role_arn}"
    },
    "AutoDeploymentsEnabled": true,
    "ImageRepository": {
      "ImageIdentifier": "${esc_image_uri}",
      "ImageRepositoryType": "ECR",
      "ImageConfiguration": {
        "Port": "8080",
        "RuntimeEnvironmentVariables": {
          "MODE": "${esc_mode}",
          "BACKEND_NAME": "${esc_backend_name}",
          "BACKENDS": "${esc_backends}",
          "STRATEGY": "${esc_strategy}",
          "PROXY_PREFIX": "${esc_proxy_prefix}",
          "HEALTH_PATH": "${esc_health_path}",
          "ENABLE_FRONTEND": "${esc_enable_frontend}"
        }
      }
    }
  },
  "InstanceConfiguration": {
    "Cpu": "${esc_cpu}",
    "Memory": "${esc_memory}"
  },
  "HealthCheckConfiguration": {
    "Protocol": "HTTP",
    "Path": "/healthz",
    "Interval": 10,
    "Timeout": 5,
    "HealthyThreshold": 1,
    "UnhealthyThreshold": 5
  }
}
JSON
    service_arn="$(aws apprunner create-service --region "${AWS_REGION}" --cli-input-json "file://${tmp_json}" --query Service.ServiceArn --output text)"
  else
    cat >"${tmp_json}" <<JSON
{
  "ServiceArn": "${service_arn}",
  "SourceConfiguration": {
    "AuthenticationConfiguration": {
      "AccessRoleArn": "${esc_role_arn}"
    },
    "AutoDeploymentsEnabled": true,
    "ImageRepository": {
      "ImageIdentifier": "${esc_image_uri}",
      "ImageRepositoryType": "ECR",
      "ImageConfiguration": {
        "Port": "8080",
        "RuntimeEnvironmentVariables": {
          "MODE": "${esc_mode}",
          "BACKEND_NAME": "${esc_backend_name}",
          "BACKENDS": "${esc_backends}",
          "STRATEGY": "${esc_strategy}",
          "PROXY_PREFIX": "${esc_proxy_prefix}",
          "HEALTH_PATH": "${esc_health_path}",
          "ENABLE_FRONTEND": "${esc_enable_frontend}"
        }
      }
    }
  },
  "InstanceConfiguration": {
    "Cpu": "${esc_cpu}",
    "Memory": "${esc_memory}"
  },
  "HealthCheckConfiguration": {
    "Protocol": "HTTP",
    "Path": "/healthz",
    "Interval": 10,
    "Timeout": 5,
    "HealthyThreshold": 1,
    "UnhealthyThreshold": 5
  }
}
JSON
    aws apprunner update-service --region "${AWS_REGION}" --cli-input-json "file://${tmp_json}" >/dev/null
  fi

  rm -f "${tmp_json}"
  printf '%s' "${service_arn}"
}

echo "[1/8] Resolving AWS account..."
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
IMAGE_TAG="$(date +%Y%m%d%H%M%S)"
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${IMAGE_TAG}"
IMAGE_LATEST_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:latest"

echo "[2/8] Ensuring ECR repository exists..."
if ! aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null
fi

echo "[3/8] Building Linux binary and pushing image..."
mkdir -p build
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o build/minilb .
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" >/dev/null
docker build --platform linux/amd64 -t "${ECR_REPO}:${IMAGE_TAG}" .
docker tag "${ECR_REPO}:${IMAGE_TAG}" "${IMAGE_URI}"
docker tag "${ECR_REPO}:${IMAGE_TAG}" "${IMAGE_LATEST_URI}"
docker push "${IMAGE_URI}" >/dev/null
docker push "${IMAGE_LATEST_URI}" >/dev/null

echo "[4/8] Ensuring App Runner ECR access role exists..."
if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  TRUST_POLICY="$(mktemp)"
  cat >"${TRUST_POLICY}" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "build.apprunner.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON
  aws iam create-role --role-name "${ROLE_NAME}" --assume-role-policy-document "file://${TRUST_POLICY}" >/dev/null
  aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess >/dev/null
  rm -f "${TRUST_POLICY}"
  sleep 12
fi
ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text)"

echo "[5/8] Deploying backend services..."
BACKEND_A_ARN="$(upsert_service "${BACKEND_A_SERVICE_NAME}" "backend_demo" "${BACKEND_A_SERVICE_NAME}" "" "${LB_STRATEGY}" "${PROXY_PREFIX}" "${HEALTH_PATH}" "false" "${BACKEND_CPU}" "${BACKEND_MEMORY}" "${ROLE_ARN}" "${IMAGE_URI}")"
BACKEND_B_ARN="$(upsert_service "${BACKEND_B_SERVICE_NAME}" "backend_demo" "${BACKEND_B_SERVICE_NAME}" "" "${LB_STRATEGY}" "${PROXY_PREFIX}" "${HEALTH_PATH}" "false" "${BACKEND_CPU}" "${BACKEND_MEMORY}" "${ROLE_ARN}" "${IMAGE_URI}")"

echo "[6/8] Waiting for backend services..."
wait_service_running "${BACKEND_A_ARN}" "${BACKEND_A_SERVICE_NAME}"
wait_service_running "${BACKEND_B_ARN}" "${BACKEND_B_SERVICE_NAME}"

BACKEND_A_URL="$(aws apprunner describe-service --region "${AWS_REGION}" --service-arn "${BACKEND_A_ARN}" --query Service.ServiceUrl --output text)"
BACKEND_B_URL="$(aws apprunner describe-service --region "${AWS_REGION}" --service-arn "${BACKEND_B_ARN}" --query Service.ServiceUrl --output text)"
LB_BACKENDS="https://${BACKEND_A_URL},https://${BACKEND_B_URL}"

echo "[7/8] Deploying load balancer service against AWS-owned backends..."
LB_ARN="$(upsert_service "${LB_SERVICE_NAME}" "load_balancer" "" "${LB_BACKENDS}" "${LB_STRATEGY}" "${PROXY_PREFIX}" "${HEALTH_PATH}" "true" "${LB_CPU}" "${LB_MEMORY}" "${ROLE_ARN}" "${IMAGE_URI}")"
wait_service_running "${LB_ARN}" "${LB_SERVICE_NAME}"
LB_URL="$(aws apprunner describe-service --region "${AWS_REGION}" --service-arn "${LB_ARN}" --query Service.ServiceUrl --output text)"

echo "[8/8] Stack deployment complete."
echo
echo "Load Balancer Service: https://${LB_URL}"
echo "Backends:"
echo "  - ${BACKEND_A_SERVICE_NAME}: https://${BACKEND_A_URL}"
echo "  - ${BACKEND_B_SERVICE_NAME}: https://${BACKEND_B_URL}"
echo
echo "Control plane: https://${LB_URL}/admin/backends"
echo "Proxy sample:  https://${LB_URL}${PROXY_PREFIX}/whoami"
