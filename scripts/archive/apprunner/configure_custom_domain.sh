#!/usr/bin/env bash
set -euo pipefail

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required." >&2
  exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
LB_SERVICE_NAME="${LB_SERVICE_NAME:-mini-load-balancer}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"

service_arn_by_name() {
  local name="$1"
  aws apprunner list-services --region "${AWS_REGION}" --query "ServiceSummaryList[?ServiceName=='${name}'].ServiceArn | [0]" --output text
}

ensure_dot() {
  local value="$1"
  if [[ "${value}" == *"." ]]; then
    printf '%s' "${value}"
  else
    printf '%s.' "${value}"
  fi
}

echo "[1/6] Resolving App Runner service..."
SERVICE_ARN="$(service_arn_by_name "${LB_SERVICE_NAME}")"
if [[ -z "${SERVICE_ARN}" || "${SERVICE_ARN}" == "None" ]]; then
  echo "Service '${LB_SERVICE_NAME}' not found in ${AWS_REGION}." >&2
  exit 1
fi
SERVICE_URL="$(aws apprunner describe-service --region "${AWS_REGION}" --service-arn "${SERVICE_ARN}" --query Service.ServiceUrl --output text)"

if [[ -z "${DOMAIN_NAME}" ]]; then
  echo "DOMAIN_NAME is required and must be a valid domain you control (for example lb.example.com)." >&2
  exit 1
fi
DOMAIN_NAME="${DOMAIN_NAME%.}"
DOMAIN_LOWER="$(printf '%s' "${DOMAIN_NAME}" | tr '[:upper:]' '[:lower:]')"

echo "[2/6] Resolving hosted zone and domain..."
ZONES_RAW="$(aws route53 list-hosted-zones --query "HostedZones[?Config.PrivateZone==\`false\`].[Id,Name]" --output text)"
if [[ -z "${ZONES_RAW}" ]]; then
  echo "No public Route 53 hosted zones found." >&2
  exit 1
fi

MATCHED_ZONE_ID=""
MATCHED_ZONE_NAME=""
MATCHED_LEN=0
while read -r zone_id zone_name; do
  [[ -z "${zone_id}" || -z "${zone_name}" ]] && continue
  zone_id="${zone_id#/hostedzone/}"
  zone_name="${zone_name%.}"
  zone_lower="$(printf '%s' "${zone_name}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${DOMAIN_LOWER}" == "${zone_lower}" || "${DOMAIN_LOWER}" == *".${zone_lower}" ]]; then
    zone_len="${#zone_lower}"
    if (( zone_len > MATCHED_LEN )); then
      MATCHED_LEN="${zone_len}"
      MATCHED_ZONE_ID="${zone_id}"
      MATCHED_ZONE_NAME="${zone_name}"
    fi
  fi
done <<< "${ZONES_RAW}"

if [[ -z "${MATCHED_ZONE_ID}" ]]; then
  echo "Could not match DOMAIN_NAME='${DOMAIN_NAME}' to a public hosted zone." >&2
  exit 1
fi

if [[ -n "${HOSTED_ZONE_ID}" ]]; then
  HOSTED_ZONE_ID="${HOSTED_ZONE_ID#/hostedzone/}"
else
  HOSTED_ZONE_ID="${MATCHED_ZONE_ID}"
fi

if [[ "${DOMAIN_LOWER}" == "$(printf '%s' "${MATCHED_ZONE_NAME}" | tr '[:upper:]' '[:lower:]')" ]]; then
  echo "Use a subdomain (for example 'lb.${MATCHED_ZONE_NAME}') instead of zone apex '${MATCHED_ZONE_NAME}'." >&2
  exit 1
fi

echo "[3/6] Associating custom domain in App Runner..."
FOUND_DOMAIN="$(aws apprunner describe-custom-domains --region "${AWS_REGION}" --service-arn "${SERVICE_ARN}" --query "CustomDomains[?DomainName=='${DOMAIN_NAME}'] | [0].DomainName" --output text || true)"
if [[ -z "${FOUND_DOMAIN}" || "${FOUND_DOMAIN}" == "None" ]]; then
  aws apprunner associate-custom-domain --region "${AWS_REGION}" --service-arn "${SERVICE_ARN}" --domain-name "${DOMAIN_NAME}" >/dev/null
fi

DNS_TARGET="$(aws apprunner describe-custom-domains --region "${AWS_REGION}" --service-arn "${SERVICE_ARN}" --query "DNSTarget" --output text)"
if [[ -z "${DNS_TARGET}" || "${DNS_TARGET}" == "None" ]]; then
  echo "Failed to resolve App Runner DNS target." >&2
  exit 1
fi

# Wait until validation records become available.
VALIDATION_ROWS=""
for _ in $(seq 1 30); do
  VALIDATION_ROWS="$(aws apprunner describe-custom-domains --region "${AWS_REGION}" --service-arn "${SERVICE_ARN}" --query "CustomDomains[?DomainName=='${DOMAIN_NAME}'] | [0].CertificateValidationRecords[*].[Name,Type,Value]" --output text)"
  if [[ -n "${VALIDATION_ROWS}" && "${VALIDATION_ROWS}" != "None" ]]; then
    break
  fi
  sleep 5
done

if [[ -z "${VALIDATION_ROWS}" || "${VALIDATION_ROWS}" == "None" ]]; then
  echo "No certificate validation records returned by App Runner yet." >&2
  exit 1
fi

echo "[4/6] Upserting Route 53 DNS records..."
TMP_BATCH="$(mktemp)"
{
  echo '{"Comment":"App Runner custom domain records","Changes":['
  first_change=1
  add_change() {
    local change="$1"
    if (( first_change == 0 )); then
      echo ','
    fi
    first_change=0
    printf '%s' "${change}"
  }

  add_change "{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$(ensure_dot "${DOMAIN_NAME}")\",\"Type\":\"CNAME\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$(ensure_dot "${DNS_TARGET}")\"}]}}"

  while IFS=$'\t' read -r rec_name rec_type rec_value; do
    [[ -z "${rec_name}" || -z "${rec_type}" || -z "${rec_value}" ]] && continue
    add_change "{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$(ensure_dot "${rec_name}")\",\"Type\":\"${rec_type}\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$(ensure_dot "${rec_value}")\"}]}}"
  done <<< "${VALIDATION_ROWS}"

  echo ']}'
} > "${TMP_BATCH}"

aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "file://${TMP_BATCH}" >/dev/null
rm -f "${TMP_BATCH}"

echo "[5/6] Waiting for certificate validation..."
for _ in $(seq 1 90); do
  DOMAIN_STATUS="$(aws apprunner describe-custom-domains --region "${AWS_REGION}" --service-arn "${SERVICE_ARN}" --query "CustomDomains[?DomainName=='${DOMAIN_NAME}'] | [0].Status" --output text)"
  if [[ "${DOMAIN_STATUS}" == "ACTIVE" ]]; then
    break
  fi
  if [[ "${DOMAIN_STATUS}" == "BINDING_CERTIFICATE" || "${DOMAIN_STATUS}" == "PENDING_CERTIFICATE_DNS_VALIDATION" || "${DOMAIN_STATUS}" == "CREATING" ]]; then
    sleep 20
    continue
  fi
  echo "Custom domain association status: ${DOMAIN_STATUS}" >&2
  sleep 20
done

FINAL_STATUS="$(aws apprunner describe-custom-domains --region "${AWS_REGION}" --service-arn "${SERVICE_ARN}" --query "CustomDomains[?DomainName=='${DOMAIN_NAME}'] | [0].Status" --output text)"
echo "[6/6] Complete."
echo
echo "Service URL:   https://${SERVICE_URL}"
echo "Custom domain: https://${DOMAIN_NAME}"
echo "Status:        ${FINAL_STATUS}"
echo "Hosted zone:   ${HOSTED_ZONE_ID} (${MATCHED_ZONE_NAME})"
