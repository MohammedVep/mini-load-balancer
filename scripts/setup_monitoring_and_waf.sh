#!/usr/bin/env bash
set -euo pipefail

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required." >&2
  exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
LB_SERVICE_NAME="${LB_SERVICE_NAME:-mini-load-balancer}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-${LB_SERVICE_NAME}-alerts}"
DASHBOARD_NAME="${DASHBOARD_NAME:-${LB_SERVICE_NAME}-ops}"
WAF_NAME="${WAF_NAME:-${LB_SERVICE_NAME}-waf}"
WAF_RATE_LIMIT="${WAF_RATE_LIMIT:-2000}"

service_arn_by_name() {
  local name="$1"
  aws apprunner list-services --region "${AWS_REGION}" --query "ServiceSummaryList[?ServiceName=='${name}'].ServiceArn | [0]" --output text
}

echo "[1/7] Resolving service metadata..."
SERVICE_ARN="$(service_arn_by_name "${LB_SERVICE_NAME}")"
if [[ -z "${SERVICE_ARN}" || "${SERVICE_ARN}" == "None" ]]; then
  echo "Service '${LB_SERVICE_NAME}' not found in ${AWS_REGION}." >&2
  exit 1
fi
SERVICE_ID="$(echo "${SERVICE_ARN}" | awk -F/ '{print $NF}')"
SERVICE_URL="$(aws apprunner describe-service --region "${AWS_REGION}" --service-arn "${SERVICE_ARN}" --query Service.ServiceUrl --output text)"

echo "[2/7] Creating SNS topic for alarms..."
SNS_TOPIC_ARN="$(aws sns create-topic --region "${AWS_REGION}" --name "${SNS_TOPIC_NAME}" --query TopicArn --output text)"
if [[ -n "${ALERT_EMAIL}" ]]; then
  EXISTING_SUB="$(aws sns list-subscriptions-by-topic --region "${AWS_REGION}" --topic-arn "${SNS_TOPIC_ARN}" --query "Subscriptions[?Protocol=='email' && Endpoint=='${ALERT_EMAIL}'] | [0].SubscriptionArn" --output text)"
  if [[ -z "${EXISTING_SUB}" || "${EXISTING_SUB}" == "None" ]]; then
    aws sns subscribe --region "${AWS_REGION}" --topic-arn "${SNS_TOPIC_ARN}" --protocol email --notification-endpoint "${ALERT_EMAIL}" >/dev/null
    echo "Email subscription created. Confirm the subscription email for alarm delivery."
  fi
fi

echo "[3/7] Provisioning CloudWatch dashboard..."
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
        "title": "CPU and Memory Utilization",
        "region": "${AWS_REGION}",
        "stat": "Average",
        "period": 60,
        "metrics": [
          [ "AWS/AppRunner", "CPUUtilization", "ServiceName", "${LB_SERVICE_NAME}", "ServiceID", "${SERVICE_ID}" ],
          [ ".", "MemoryUtilization", ".", ".", ".", "." ]
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
        "title": "Traffic and Errors",
        "region": "${AWS_REGION}",
        "stat": "Sum",
        "period": 60,
        "metrics": [
          [ "AWS/AppRunner", "Requests", "ServiceName", "${LB_SERVICE_NAME}", "ServiceID", "${SERVICE_ID}" ],
          [ ".", "2xxStatusResponses", ".", ".", ".", "." ],
          [ ".", "4xxStatusResponses", ".", ".", ".", "." ],
          [ ".", "5xxStatusResponses", ".", ".", ".", "." ]
        ]
      }
    },
    {
      "type": "metric",
      "x": 0,
      "y": 6,
      "width": 24,
      "height": 6,
      "properties": {
        "title": "P95 Request Latency",
        "region": "${AWS_REGION}",
        "period": 60,
        "stat": "p95",
        "metrics": [
          [ "AWS/AppRunner", "RequestLatency", "ServiceName", "${LB_SERVICE_NAME}", "ServiceID", "${SERVICE_ID}" ]
        ]
      }
    }
  ]
}
JSON
)"
aws cloudwatch put-dashboard --region "${AWS_REGION}" --dashboard-name "${DASHBOARD_NAME}" --dashboard-body "${DASHBOARD_BODY}" >/dev/null

echo "[4/7] Creating CloudWatch alarms..."
DIMENSIONS="Name=ServiceName,Value=${LB_SERVICE_NAME} Name=ServiceID,Value=${SERVICE_ID}"
aws cloudwatch put-metric-alarm --region "${AWS_REGION}" \
  --alarm-name "${LB_SERVICE_NAME}-cpu-high" \
  --alarm-description "CPU utilization is high for ${LB_SERVICE_NAME}" \
  --namespace AWS/AppRunner \
  --metric-name CPUUtilization \
  --dimensions ${DIMENSIONS} \
  --statistic Average \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 75 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" >/dev/null

aws cloudwatch put-metric-alarm --region "${AWS_REGION}" \
  --alarm-name "${LB_SERVICE_NAME}-memory-high" \
  --alarm-description "Memory utilization is high for ${LB_SERVICE_NAME}" \
  --namespace AWS/AppRunner \
  --metric-name MemoryUtilization \
  --dimensions ${DIMENSIONS} \
  --statistic Average \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" >/dev/null

aws cloudwatch put-metric-alarm --region "${AWS_REGION}" \
  --alarm-name "${LB_SERVICE_NAME}-5xx-high" \
  --alarm-description "5xx responses detected for ${LB_SERVICE_NAME}" \
  --namespace AWS/AppRunner \
  --metric-name 5xxStatusResponses \
  --dimensions ${DIMENSIONS} \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 5 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" >/dev/null

aws cloudwatch put-metric-alarm --region "${AWS_REGION}" \
  --alarm-name "${LB_SERVICE_NAME}-latency-p95-high" \
  --alarm-description "P95 request latency high for ${LB_SERVICE_NAME}" \
  --namespace AWS/AppRunner \
  --metric-name RequestLatency \
  --dimensions ${DIMENSIONS} \
  --extended-statistic p95 \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 1000 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" >/dev/null

echo "[5/7] Ensuring WAF Web ACL exists..."
WEB_ACL_ARN="$(aws wafv2 list-web-acls --scope REGIONAL --region "${AWS_REGION}" --query "WebACLs[?Name=='${WAF_NAME}'] | [0].ARN" --output text)"
if [[ -z "${WEB_ACL_ARN}" || "${WEB_ACL_ARN}" == "None" ]]; then
  TMP_WAF_JSON="$(mktemp)"
  cat >"${TMP_WAF_JSON}" <<JSON
{
  "Name": "${WAF_NAME}",
  "Scope": "REGIONAL",
  "Description": "Managed protection for ${LB_SERVICE_NAME}",
  "DefaultAction": {
    "Allow": {}
  },
  "VisibilityConfig": {
    "SampledRequestsEnabled": true,
    "CloudWatchMetricsEnabled": true,
    "MetricName": "${WAF_NAME}"
  },
  "Rules": [
    {
      "Name": "AWSManagedCommonRuleSet",
      "Priority": 0,
      "Statement": {
        "ManagedRuleGroupStatement": {
          "VendorName": "AWS",
          "Name": "AWSManagedRulesCommonRuleSet"
        }
      },
      "OverrideAction": {
        "None": {}
      },
      "VisibilityConfig": {
        "SampledRequestsEnabled": true,
        "CloudWatchMetricsEnabled": true,
        "MetricName": "managed-common"
      }
    },
    {
      "Name": "AWSManagedKnownBadInputsRuleSet",
      "Priority": 1,
      "Statement": {
        "ManagedRuleGroupStatement": {
          "VendorName": "AWS",
          "Name": "AWSManagedRulesKnownBadInputsRuleSet"
        }
      },
      "OverrideAction": {
        "None": {}
      },
      "VisibilityConfig": {
        "SampledRequestsEnabled": true,
        "CloudWatchMetricsEnabled": true,
        "MetricName": "managed-bad-inputs"
      }
    },
    {
      "Name": "RateLimitPerIP",
      "Priority": 2,
      "Statement": {
        "RateBasedStatement": {
          "Limit": ${WAF_RATE_LIMIT},
          "AggregateKeyType": "IP"
        }
      },
      "Action": {
        "Block": {}
      },
      "VisibilityConfig": {
        "SampledRequestsEnabled": true,
        "CloudWatchMetricsEnabled": true,
        "MetricName": "rate-limit"
      }
    }
  ]
}
JSON
  WEB_ACL_ARN="$(aws wafv2 create-web-acl --region "${AWS_REGION}" --cli-input-json "file://${TMP_WAF_JSON}" --query Summary.ARN --output text)"
  rm -f "${TMP_WAF_JSON}"
fi

echo "[6/7] Associating WAF Web ACL to App Runner service..."
CURRENT_WEB_ACL_ARN="$(aws wafv2 get-web-acl-for-resource --region "${AWS_REGION}" --resource-arn "${SERVICE_ARN}" --query 'WebACL.ARN' --output text 2>/dev/null || true)"
if [[ "${CURRENT_WEB_ACL_ARN}" != "${WEB_ACL_ARN}" ]]; then
  if [[ -n "${CURRENT_WEB_ACL_ARN}" && "${CURRENT_WEB_ACL_ARN}" != "None" ]]; then
    aws wafv2 disassociate-web-acl --region "${AWS_REGION}" --resource-arn "${SERVICE_ARN}" >/dev/null || true
  fi
  TMP_ASSOCIATE_ERR="$(mktemp)"
  ASSOCIATED=0
  for _ in $(seq 1 20); do
    if aws wafv2 associate-web-acl --region "${AWS_REGION}" --web-acl-arn "${WEB_ACL_ARN}" --resource-arn "${SERVICE_ARN}" >/dev/null 2>"${TMP_ASSOCIATE_ERR}"; then
      ASSOCIATED=1
      break
    fi
    if grep -q "WAFUnavailableEntityException" "${TMP_ASSOCIATE_ERR}"; then
      sleep 10
      continue
    fi
    cat "${TMP_ASSOCIATE_ERR}" >&2
    rm -f "${TMP_ASSOCIATE_ERR}"
    exit 1
  done
  rm -f "${TMP_ASSOCIATE_ERR}"
  if [[ "${ASSOCIATED}" -ne 1 ]]; then
    echo "Failed to associate WAF Web ACL after retries." >&2
    exit 1
  fi
fi

echo "[7/7] Monitoring and security setup complete."
echo
echo "Service URL:      https://${SERVICE_URL}"
echo "SNS topic:        ${SNS_TOPIC_ARN}"
echo "Dashboard URL:    https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#dashboards:name=${DASHBOARD_NAME}"
echo "WAF Web ACL ARN:  ${WEB_ACL_ARN}"
if [[ -n "${ALERT_EMAIL}" ]]; then
  echo "Alert email:      ${ALERT_EMAIL} (confirm subscription if pending)"
fi
