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

APP_NAME="${APP_NAME:-mini-load-balancer}"
AWS_REGION="${AWS_REGION:-us-east-1}"
MODE="${MODE:-load_balancer}"
BACKEND_NAME="${BACKEND_NAME:-}"
BACKENDS="${BACKENDS:-}"
STRATEGY="${STRATEGY:-round_robin}"
PROXY_PREFIX="${PROXY_PREFIX:-/proxy}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
ENABLE_FRONTEND="${ENABLE_FRONTEND:-true}"
INSTANCE_CPU="${INSTANCE_CPU:-1024}"
INSTANCE_MEMORY="${INSTANCE_MEMORY:-2048}"

if [[ "${MODE}" == "load_balancer" && -z "${BACKENDS}" ]]; then
  echo "BACKENDS env var is required. Example:" >&2
  echo "BACKENDS='http://demo-a.example.com,http://demo-b.example.com' ./scripts/deploy_aws_apprunner.sh" >&2
  exit 1
fi

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REPO="${ECR_REPO:-$APP_NAME}"
ROLE_NAME="${ROLE_NAME:-${APP_NAME}-apprunner-ecr-role}"
IMAGE_TAG="$(date +%Y%m%d%H%M%S)"
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${IMAGE_TAG}"
IMAGE_LATEST_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:latest"

echo "[1/6] Ensuring ECR repository exists..."
if ! aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null
fi

echo "[2/6] Building Linux binary..."
mkdir -p build
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o build/minilb .

echo "[3/6] Building and pushing image..."
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" >/dev/null
docker build --platform linux/amd64 -t "${ECR_REPO}:${IMAGE_TAG}" .
docker tag "${ECR_REPO}:${IMAGE_TAG}" "${IMAGE_URI}"
docker tag "${ECR_REPO}:${IMAGE_TAG}" "${IMAGE_LATEST_URI}"
docker push "${IMAGE_URI}" >/dev/null
docker push "${IMAGE_LATEST_URI}" >/dev/null

echo "[4/6] Ensuring App Runner ECR access role exists..."
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
  # IAM propagation delay
  sleep 12
fi
ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text)"

echo "[5/7] Creating or updating App Runner service..."
SERVICE_ARN="$(aws apprunner list-services --region "${AWS_REGION}" --query "ServiceSummaryList[?ServiceName=='${APP_NAME}'].ServiceArn | [0]" --output text)"
TMP_JSON="$(mktemp)"

ESC_APP_NAME="$(json_escape "${APP_NAME}")"
ESC_IMAGE_URI="$(json_escape "${IMAGE_URI}")"
ESC_ROLE_ARN="$(json_escape "${ROLE_ARN}")"
ESC_MODE="$(json_escape "${MODE}")"
ESC_BACKEND_NAME="$(json_escape "${BACKEND_NAME}")"
ESC_BACKENDS="$(json_escape "${BACKENDS}")"
ESC_STRATEGY="$(json_escape "${STRATEGY}")"
ESC_PROXY_PREFIX="$(json_escape "${PROXY_PREFIX}")"
ESC_HEALTH_PATH="$(json_escape "${HEALTH_PATH}")"
ESC_ENABLE_FRONTEND="$(json_escape "${ENABLE_FRONTEND}")"

if [[ -z "${SERVICE_ARN}" || "${SERVICE_ARN}" == "None" ]]; then
  cat >"${TMP_JSON}" <<JSON
{
  "ServiceName": "${ESC_APP_NAME}",
  "SourceConfiguration": {
    "AuthenticationConfiguration": {
      "AccessRoleArn": "${ESC_ROLE_ARN}"
    },
    "AutoDeploymentsEnabled": true,
    "ImageRepository": {
      "ImageIdentifier": "${ESC_IMAGE_URI}",
      "ImageRepositoryType": "ECR",
      "ImageConfiguration": {
        "Port": "8080",
        "RuntimeEnvironmentVariables": {
          "MODE": "${ESC_MODE}",
          "BACKEND_NAME": "${ESC_BACKEND_NAME}",
          "BACKENDS": "${ESC_BACKENDS}",
          "STRATEGY": "${ESC_STRATEGY}",
          "PROXY_PREFIX": "${ESC_PROXY_PREFIX}",
          "HEALTH_PATH": "${ESC_HEALTH_PATH}",
          "ENABLE_FRONTEND": "${ESC_ENABLE_FRONTEND}"
        }
      }
    }
  },
  "InstanceConfiguration": {
    "Cpu": "${INSTANCE_CPU}",
    "Memory": "${INSTANCE_MEMORY}"
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
  SERVICE_ARN="$(aws apprunner create-service --region "${AWS_REGION}" --cli-input-json "file://${TMP_JSON}" --query Service.ServiceArn --output text)"
else
  cat >"${TMP_JSON}" <<JSON
{
  "ServiceArn": "${SERVICE_ARN}",
  "SourceConfiguration": {
    "AuthenticationConfiguration": {
      "AccessRoleArn": "${ESC_ROLE_ARN}"
    },
    "AutoDeploymentsEnabled": true,
    "ImageRepository": {
      "ImageIdentifier": "${ESC_IMAGE_URI}",
      "ImageRepositoryType": "ECR",
      "ImageConfiguration": {
        "Port": "8080",
        "RuntimeEnvironmentVariables": {
          "MODE": "${ESC_MODE}",
          "BACKEND_NAME": "${ESC_BACKEND_NAME}",
          "BACKENDS": "${ESC_BACKENDS}",
          "STRATEGY": "${ESC_STRATEGY}",
          "PROXY_PREFIX": "${ESC_PROXY_PREFIX}",
          "HEALTH_PATH": "${ESC_HEALTH_PATH}",
          "ENABLE_FRONTEND": "${ESC_ENABLE_FRONTEND}"
        }
      }
    }
  },
  "InstanceConfiguration": {
    "Cpu": "${INSTANCE_CPU}",
    "Memory": "${INSTANCE_MEMORY}"
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
  aws apprunner update-service --region "${AWS_REGION}" --cli-input-json "file://${TMP_JSON}" >/dev/null
fi

rm -f "${TMP_JSON}"

echo "[6/7] Waiting for App Runner service to reach RUNNING..."
for _ in $(seq 1 90); do
  STATUS="$(aws apprunner describe-service --region "${AWS_REGION}" --service-arn "${SERVICE_ARN}" --query Service.Status --output text)"
  if [[ "${STATUS}" == "RUNNING" ]]; then
    break
  fi
  if [[ "${STATUS}" == "CREATE_FAILED" || "${STATUS}" == "DELETE_FAILED" || "${STATUS}" == "OPERATION_FAILED" ]]; then
    echo "App Runner deployment failed with status: ${STATUS}" >&2
    exit 1
  fi
  sleep 10
done

FINAL_STATUS="$(aws apprunner describe-service --region "${AWS_REGION}" --service-arn "${SERVICE_ARN}" --query Service.Status --output text)"
if [[ "${FINAL_STATUS}" != "RUNNING" ]]; then
  echo "Timed out waiting for RUNNING status (last status: ${FINAL_STATUS})." >&2
  exit 1
fi

echo "[7/7] Deployment complete."
SERVICE_URL="$(aws apprunner describe-service --region "${AWS_REGION}" --service-arn "${SERVICE_ARN}" --query Service.ServiceUrl --output text)"
echo
echo "Service URL: https://${SERVICE_URL}"
echo "Homepage:    https://${SERVICE_URL}/"
echo "Admin API:   https://${SERVICE_URL}/admin/backends"
echo "Proxy path:  https://${SERVICE_URL}${PROXY_PREFIX}/"
