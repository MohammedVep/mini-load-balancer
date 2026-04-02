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

APP_NAME="${APP_NAME:-mini-load-balancer}"
ECS_CLUSTER="${ECS_CLUSTER:-mini-load-balancer-fargate}"
LB_SERVICE_NAME="${LB_SERVICE_NAME:-mini-load-balancer-ecs}"
BACKEND_A_SERVICE_NAME="${BACKEND_A_SERVICE_NAME:-mini-load-balancer-backend-a-ecs}"
BACKEND_B_SERVICE_NAME="${BACKEND_B_SERVICE_NAME:-mini-load-balancer-backend-b-ecs}"
ALB_NAME="${ALB_NAME:-mini-load-balancer-ecs-alb}"
CLOUDFRONT_DISTRIBUTION_ID="${CLOUDFRONT_DISTRIBUTION_ID:-E1BF6B0VQTLRKS}"

SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-${APP_NAME}-alerts}"
DASHBOARD_NAME="${DASHBOARD_NAME:-${APP_NAME}-ecs-ops}"
ALERT_EMAIL="${ALERT_EMAIL:-}"

AWS_ARGS=(--region "${AWS_REGION}" --no-cli-pager)
if [[ -n "${AWS_PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${AWS_PROFILE}")
fi

aws_cli() {
  "${AWS_BIN}" "${AWS_ARGS[@]}" "$@"
}

require_text() {
  local value="$1"
  local label="$2"
  if [[ -z "${value}" || "${value}" == "None" || "${value}" == "null" ]]; then
    echo "Unable to resolve ${label}." >&2
    exit 1
  fi
}

ensure_subscription() {
  local topic_arn="$1"
  local email="$2"
  local existing

  existing="$(aws_cli sns list-subscriptions-by-topic --topic-arn "${topic_arn}" --query "Subscriptions[?Protocol=='email' && Endpoint=='${email}'] | [0].SubscriptionArn" --output text)"
  if [[ -z "${existing}" || "${existing}" == "None" ]]; then
    aws_cli sns subscribe --topic-arn "${topic_arn}" --protocol email --notification-endpoint "${email}" >/dev/null
    echo "Created email subscription for ${email}. Confirm the SNS email before relying on alerts." >&2
  fi
}

echo "[1/4] Resolving live ECS, ALB, and CloudFront resources..."
LB_SERVICE_STATUS="$(aws_cli ecs describe-services --cluster "${ECS_CLUSTER}" --services "${LB_SERVICE_NAME}" --query 'services[0].status' --output text)"
require_text "${LB_SERVICE_STATUS}" "ECS service ${LB_SERVICE_NAME}"

LB_TG_ARN="$(aws_cli ecs describe-services --cluster "${ECS_CLUSTER}" --services "${LB_SERVICE_NAME}" --query 'services[0].loadBalancers[0].targetGroupArn' --output text)"
require_text "${LB_TG_ARN}" "target group for ${LB_SERVICE_NAME}"

ALB_ARN="$(aws_cli elbv2 describe-load-balancers --names "${ALB_NAME}" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
require_text "${ALB_ARN}" "ALB ${ALB_NAME}"

CF_STATUS="$(aws_cli cloudfront get-distribution --id "${CLOUDFRONT_DISTRIBUTION_ID}" --query 'Distribution.Status' --output text)"
require_text "${CF_STATUS}" "CloudFront distribution ${CLOUDFRONT_DISTRIBUTION_ID}"

LB_DIMENSION="${ALB_ARN#*loadbalancer/}"
TG_DIMENSION="targetgroup/${LB_TG_ARN#*targetgroup/}"

SNS_TOPIC_ARN="$(aws_cli sns create-topic --name "${SNS_TOPIC_NAME}" --query 'TopicArn' --output text)"
require_text "${SNS_TOPIC_ARN}" "SNS topic ${SNS_TOPIC_NAME}"

if [[ -n "${ALERT_EMAIL}" ]]; then
  ensure_subscription "${SNS_TOPIC_ARN}" "${ALERT_EMAIL}"
fi

echo "[2/4] Writing CloudWatch dashboard ${DASHBOARD_NAME}..."
DASHBOARD_BODY="$(cat <<JSON
{
  "widgets": [
    {
      "type": "metric",
      "x": 0,
      "y": 0,
      "width": 12,
      "height": 6,
      "properties": {
        "title": "ECS Service CPU Utilization",
        "region": "${AWS_REGION}",
        "view": "timeSeries",
        "stat": "Average",
        "period": 60,
        "metrics": [
          [ "AWS/ECS", "CPUUtilization", "ClusterName", "${ECS_CLUSTER}", "ServiceName", "${LB_SERVICE_NAME}" ],
          [ ".", ".", ".", ".", ".", "${BACKEND_A_SERVICE_NAME}" ],
          [ ".", ".", ".", ".", ".", "${BACKEND_B_SERVICE_NAME}" ]
        ]
      }
    },
    {
      "type": "metric",
      "x": 12,
      "y": 0,
      "width": 12,
      "height": 6,
      "properties": {
        "title": "ECS Service Memory Utilization",
        "region": "${AWS_REGION}",
        "view": "timeSeries",
        "stat": "Average",
        "period": 60,
        "metrics": [
          [ "AWS/ECS", "MemoryUtilization", "ClusterName", "${ECS_CLUSTER}", "ServiceName", "${LB_SERVICE_NAME}" ],
          [ ".", ".", ".", ".", ".", "${BACKEND_A_SERVICE_NAME}" ],
          [ ".", ".", ".", ".", ".", "${BACKEND_B_SERVICE_NAME}" ]
        ]
      }
    },
    {
      "type": "metric",
      "x": 0,
      "y": 6,
      "width": 12,
      "height": 6,
      "properties": {
        "title": "ALB Request Volume and 5xx",
        "region": "${AWS_REGION}",
        "view": "timeSeries",
        "period": 60,
        "stat": "Sum",
        "metrics": [
          [ "AWS/ApplicationELB", "RequestCount", "LoadBalancer", "${LB_DIMENSION}" ],
          [ ".", "HTTPCode_ELB_5XX_Count", ".", "." ],
          [ ".", "HTTPCode_Target_5XX_Count", ".", ".", "TargetGroup", "${TG_DIMENSION}" ]
        ]
      }
    },
    {
      "type": "metric",
      "x": 12,
      "y": 6,
      "width": 12,
      "height": 6,
      "properties": {
        "title": "ALB Latency and Healthy Hosts",
        "region": "${AWS_REGION}",
        "view": "timeSeries",
        "period": 60,
        "metrics": [
          [ "AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "${LB_DIMENSION}", "TargetGroup", "${TG_DIMENSION}", { "stat": "p95", "label": "TargetResponseTime p95" } ],
          [ ".", "HealthyHostCount", ".", ".", ".", ".", { "stat": "Minimum", "label": "HealthyHostCount" } ]
        ]
      }
    },
    {
      "type": "metric",
      "x": 0,
      "y": 12,
      "width": 24,
      "height": 6,
      "properties": {
        "title": "CloudFront Edge Requests and Error Rates",
        "region": "us-east-1",
        "view": "timeSeries",
        "period": 60,
        "metrics": [
          [ "AWS/CloudFront", "Requests", "DistributionId", "${CLOUDFRONT_DISTRIBUTION_ID}", "Region", "Global", { "stat": "Sum" } ],
          [ ".", "4xxErrorRate", ".", ".", ".", ".", { "stat": "Average" } ],
          [ ".", "5xxErrorRate", ".", ".", ".", ".", { "stat": "Average" } ],
          [ ".", "BytesDownloaded", ".", ".", ".", ".", { "stat": "Sum", "yAxis": "right" } ]
        ]
      }
    }
  ]
}
JSON
)"
aws_cli cloudwatch put-dashboard --dashboard-name "${DASHBOARD_NAME}" --dashboard-body "${DASHBOARD_BODY}" >/dev/null

echo "[3/4] Creating CloudWatch alarms..."
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "${APP_NAME}-ecs-cpu-high" \
  --alarm-description "ECS load balancer service CPU is high" \
  --namespace AWS/ECS \
  --metric-name CPUUtilization \
  --dimensions Name=ClusterName,Value=${ECS_CLUSTER} Name=ServiceName,Value=${LB_SERVICE_NAME} \
  --statistic Average \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 75 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" >/dev/null

aws_cli cloudwatch put-metric-alarm \
  --alarm-name "${APP_NAME}-ecs-memory-high" \
  --alarm-description "ECS load balancer service memory is high" \
  --namespace AWS/ECS \
  --metric-name MemoryUtilization \
  --dimensions Name=ClusterName,Value=${ECS_CLUSTER} Name=ServiceName,Value=${LB_SERVICE_NAME} \
  --statistic Average \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" >/dev/null

aws_cli cloudwatch put-metric-alarm \
  --alarm-name "${APP_NAME}-alb-target-5xx-high" \
  --alarm-description "ALB target 5xx responses detected" \
  --namespace AWS/ApplicationELB \
  --metric-name HTTPCode_Target_5XX_Count \
  --dimensions Name=LoadBalancer,Value=${LB_DIMENSION} Name=TargetGroup,Value=${TG_DIMENSION} \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 5 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" >/dev/null

aws_cli cloudwatch put-metric-alarm \
  --alarm-name "${APP_NAME}-alb-unhealthy-hosts" \
  --alarm-description "ALB target group lost healthy targets" \
  --namespace AWS/ApplicationELB \
  --metric-name HealthyHostCount \
  --dimensions Name=LoadBalancer,Value=${LB_DIMENSION} Name=TargetGroup,Value=${TG_DIMENSION} \
  --statistic Minimum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 1 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" >/dev/null

aws_cli cloudwatch put-metric-alarm \
  --alarm-name "${APP_NAME}-alb-latency-p95-high" \
  --alarm-description "ALB p95 target response time is high" \
  --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime \
  --dimensions Name=LoadBalancer,Value=${LB_DIMENSION} Name=TargetGroup,Value=${TG_DIMENSION} \
  --extended-statistic p95 \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 1 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" >/dev/null

aws_cli cloudwatch put-metric-alarm \
  --alarm-name "${APP_NAME}-cloudfront-5xx-rate-high" \
  --alarm-description "CloudFront 5xx error rate is high" \
  --namespace AWS/CloudFront \
  --metric-name 5xxErrorRate \
  --dimensions Name=DistributionId,Value=${CLOUDFRONT_DISTRIBUTION_ID} Name=Region,Value=Global \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 1 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" >/dev/null

echo "[4/4] Complete."
echo
printf 'Dashboard:   %s\n' "${DASHBOARD_NAME}"
printf 'SNS topic:   %s\n' "${SNS_TOPIC_ARN}"
printf 'ALB:         %s\n' "${ALB_NAME}"
printf 'Distribution: %s\n' "${CLOUDFRONT_DISTRIBUTION_ID}"
