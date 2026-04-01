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
AWS_PROFILE="${AWS_PROFILE:-}"

ALB_DNS_NAME="${ALB_DNS_NAME:-mini-load-balancer-ecs-alb-1270380943.us-east-1.elb.amazonaws.com}"
DISTRIBUTION_COMMENT="${DISTRIBUTION_COMMENT:-mini-load-balancer-ecs-frontdoor}"
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"
PRICE_CLASS="${PRICE_CLASS:-PriceClass_100}"

CACHING_DISABLED_POLICY_ID="${CACHING_DISABLED_POLICY_ID:-4135ea2d-6df8-44a3-9df3-4b5a84be39ad}"
ALL_VIEWER_EXCEPT_HOST_POLICY_ID="${ALL_VIEWER_EXCEPT_HOST_POLICY_ID:-b689b0a8-53d0-40ab-baf2-68738e2966ac}"

AWS_ARGS=(--no-cli-pager)
if [[ -n "${AWS_PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${AWS_PROFILE}")
fi

aws_cli() {
  "${AWS_BIN}" "${AWS_ARGS[@]}" "$@"
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

distribution_id_by_comment() {
  aws_cli cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='${DISTRIBUTION_COMMENT}'].Id | [0]" \
    --output text 2>/dev/null || true
}

distribution_domain_by_id() {
  local distribution_id="$1"
  aws_cli cloudfront get-distribution \
    --id "${distribution_id}" \
    --query 'Distribution.DomainName' \
    --output text
}

wait_distribution_deployed() {
  local distribution_id="$1"
  local status=""

  for _ in $(seq 1 90); do
    status="$(aws_cli cloudfront get-distribution --id "${distribution_id}" --query 'Distribution.Status' --output text)"
    if [[ "${status}" == "Deployed" ]]; then
      return 0
    fi
    sleep 20
  done

  echo "Timed out waiting for CloudFront distribution ${distribution_id} to reach Deployed." >&2
  return 1
}

request_certificate() {
  local domain_name="$1"
  aws_cli acm request-certificate \
    --region us-east-1 \
    --domain-name "${domain_name}" \
    --validation-method DNS \
    --query 'CertificateArn' --output text
}

find_issued_certificate() {
  local domain_name="$1"
  aws_cli acm list-certificates \
    --region us-east-1 \
    --certificate-statuses ISSUED PENDING_VALIDATION \
    --query "CertificateSummaryList[?DomainName=='${domain_name}'].CertificateArn | [0]" \
    --output text 2>/dev/null || true
}

ensure_certificate_validation_record() {
  local certificate_arn="$1"
  local hosted_zone_id="$2"

  local domain_name record_name record_value change_batch
  domain_name="$(aws_cli acm describe-certificate --region us-east-1 --certificate-arn "${certificate_arn}" --query 'Certificate.DomainName' --output text)"
  record_name="$(aws_cli acm describe-certificate --region us-east-1 --certificate-arn "${certificate_arn}" --query "Certificate.DomainValidationOptions[?DomainName=='${domain_name}'].ResourceRecord.Name | [0]" --output text)"
  record_value="$(aws_cli acm describe-certificate --region us-east-1 --certificate-arn "${certificate_arn}" --query "Certificate.DomainValidationOptions[?DomainName=='${domain_name}'].ResourceRecord.Value | [0]" --output text)"

  if [[ -z "${record_name}" || "${record_name}" == "None" || -z "${record_value}" || "${record_value}" == "None" ]]; then
    echo "Certificate validation record is not available yet for ${certificate_arn}." >&2
    return 1
  fi

  change_batch="$(mktemp)"
  cat >"${change_batch}" <<JSON
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$(json_escape "${record_name}")",
        "Type": "CNAME",
        "TTL": 60,
        "ResourceRecords": [
          {
            "Value": "$(json_escape "${record_value}")"
          }
        ]
      }
    }
  ]
}
JSON

  aws_cli route53 change-resource-record-sets \
    --hosted-zone-id "${hosted_zone_id}" \
    --change-batch "file://${change_batch}" >/dev/null
  rm -f "${change_batch}"
}

wait_certificate_issued() {
  local certificate_arn="$1"
  local status=""

  for _ in $(seq 1 90); do
    status="$(aws_cli acm describe-certificate --region us-east-1 --certificate-arn "${certificate_arn}" --query 'Certificate.Status' --output text)"
    if [[ "${status}" == "ISSUED" ]]; then
      return 0
    fi
    if [[ "${status}" == "FAILED" ]]; then
      echo "Certificate request failed for ${certificate_arn}." >&2
      return 1
    fi
    sleep 20
  done

  echo "Timed out waiting for ACM certificate ${certificate_arn} to reach ISSUED." >&2
  return 1
}

upsert_alias_record() {
  local hosted_zone_id="$1"
  local record_name="$2"
  local target_name="$3"
  local target_zone_id="Z2FDTNDATAQYW2"
  local change_batch

  change_batch="$(mktemp)"
  cat >"${change_batch}" <<JSON
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$(json_escape "${record_name}")",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${target_zone_id}",
          "DNSName": "$(json_escape "${target_name}")",
          "EvaluateTargetHealth": false
        }
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$(json_escape "${record_name}")",
        "Type": "AAAA",
        "AliasTarget": {
          "HostedZoneId": "${target_zone_id}",
          "DNSName": "$(json_escape "${target_name}")",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
JSON

  aws_cli route53 change-resource-record-sets \
    --hosted-zone-id "${hosted_zone_id}" \
    --change-batch "file://${change_batch}" >/dev/null
  rm -f "${change_batch}"
}

create_distribution() {
  local certificate_arn="$1"
  local payload_file distribution_id

  payload_file="$(mktemp)"
  if [[ -n "${CUSTOM_DOMAIN}" ]]; then
    cat >"${payload_file}" <<JSON
{
  "CallerReference": "$(date +%s)-${DISTRIBUTION_COMMENT}",
  "Comment": "$(json_escape "${DISTRIBUTION_COMMENT}")",
  "Enabled": true,
  "PriceClass": "$(json_escape "${PRICE_CLASS}")",
  "HttpVersion": "http2",
  "IsIPV6Enabled": true,
  "Aliases": {
    "Quantity": 1,
    "Items": [
      "$(json_escape "${CUSTOM_DOMAIN}")"
    ]
  },
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "ecs-alb-origin",
        "DomainName": "$(json_escape "${ALB_DNS_NAME}")",
        "OriginPath": "",
        "CustomHeaders": {
          "Quantity": 0
        },
        "CustomOriginConfig": {
          "HTTPPort": 80,
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "http-only",
          "OriginSslProtocols": {
            "Quantity": 1,
            "Items": [
              "TLSv1.2"
            ]
          },
          "OriginReadTimeout": 30,
          "OriginKeepaliveTimeout": 5
        },
        "ConnectionAttempts": 3,
        "ConnectionTimeout": 10
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "ecs-alb-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": [
        "GET",
        "HEAD",
        "OPTIONS",
        "PUT",
        "POST",
        "PATCH",
        "DELETE"
      ],
      "CachedMethods": {
        "Quantity": 2,
        "Items": [
          "GET",
          "HEAD"
        ]
      }
    },
    "Compress": true,
    "CachePolicyId": "$(json_escape "${CACHING_DISABLED_POLICY_ID}")",
    "OriginRequestPolicyId": "$(json_escape "${ALL_VIEWER_EXCEPT_HOST_POLICY_ID}")"
  },
  "ViewerCertificate": {
    "ACMCertificateArn": "$(json_escape "${certificate_arn}")",
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021",
    "Certificate": "$(json_escape "${certificate_arn}")",
    "CertificateSource": "acm"
  },
  "Restrictions": {
    "GeoRestriction": {
      "RestrictionType": "none",
      "Quantity": 0
    }
  }
}
JSON
  else
    cat >"${payload_file}" <<JSON
{
  "CallerReference": "$(date +%s)-${DISTRIBUTION_COMMENT}",
  "Comment": "$(json_escape "${DISTRIBUTION_COMMENT}")",
  "Enabled": true,
  "PriceClass": "$(json_escape "${PRICE_CLASS}")",
  "HttpVersion": "http2",
  "IsIPV6Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "ecs-alb-origin",
        "DomainName": "$(json_escape "${ALB_DNS_NAME}")",
        "OriginPath": "",
        "CustomHeaders": {
          "Quantity": 0
        },
        "CustomOriginConfig": {
          "HTTPPort": 80,
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "http-only",
          "OriginSslProtocols": {
            "Quantity": 1,
            "Items": [
              "TLSv1.2"
            ]
          },
          "OriginReadTimeout": 30,
          "OriginKeepaliveTimeout": 5
        },
        "ConnectionAttempts": 3,
        "ConnectionTimeout": 10
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "ecs-alb-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": [
        "GET",
        "HEAD",
        "OPTIONS",
        "PUT",
        "POST",
        "PATCH",
        "DELETE"
      ],
      "CachedMethods": {
        "Quantity": 2,
        "Items": [
          "GET",
          "HEAD"
        ]
      }
    },
    "Compress": true,
    "CachePolicyId": "$(json_escape "${CACHING_DISABLED_POLICY_ID}")",
    "OriginRequestPolicyId": "$(json_escape "${ALL_VIEWER_EXCEPT_HOST_POLICY_ID}")"
  },
  "ViewerCertificate": {
    "CloudFrontDefaultCertificate": true,
    "MinimumProtocolVersion": "TLSv1.2_2021"
  },
  "Restrictions": {
    "GeoRestriction": {
      "RestrictionType": "none",
      "Quantity": 0
    }
  }
}
JSON
  fi

  distribution_id="$(aws_cli cloudfront create-distribution --distribution-config "file://${payload_file}" --query 'Distribution.Id' --output text)"
  rm -f "${payload_file}"
  printf '%s' "${distribution_id}"
}

echo "[1/5] Checking for an existing front door..."
EXISTING_DISTRIBUTION_ID="$(distribution_id_by_comment)"
if [[ -n "${EXISTING_DISTRIBUTION_ID}" && "${EXISTING_DISTRIBUTION_ID}" != "None" ]]; then
  EXISTING_DOMAIN="$(distribution_domain_by_id "${EXISTING_DISTRIBUTION_ID}")"
  echo "CloudFront front door already exists."
  echo "  Distribution ID: ${EXISTING_DISTRIBUTION_ID}"
  echo "  Domain:          https://${EXISTING_DOMAIN}"
  exit 0
fi

CERTIFICATE_ARN=""
if [[ -n "${CUSTOM_DOMAIN}" ]]; then
  if [[ -z "${HOSTED_ZONE_ID}" ]]; then
    echo "HOSTED_ZONE_ID is required when CUSTOM_DOMAIN is set." >&2
    exit 1
  fi

  echo "[2/5] Ensuring ACM certificate for ${CUSTOM_DOMAIN}..."
  CERTIFICATE_ARN="$(find_issued_certificate "${CUSTOM_DOMAIN}")"
  if [[ -z "${CERTIFICATE_ARN}" || "${CERTIFICATE_ARN}" == "None" ]]; then
    CERTIFICATE_ARN="$(request_certificate "${CUSTOM_DOMAIN}")"
  fi
  ensure_certificate_validation_record "${CERTIFICATE_ARN}" "${HOSTED_ZONE_ID}"
  wait_certificate_issued "${CERTIFICATE_ARN}"
else
  echo "[2/5] Skipping ACM/custom-domain setup. CloudFront default domain will be used."
fi

echo "[3/5] Creating CloudFront distribution..."
DISTRIBUTION_ID="$(create_distribution "${CERTIFICATE_ARN}")"

echo "[4/5] Waiting for CloudFront distribution to deploy..."
wait_distribution_deployed "${DISTRIBUTION_ID}"
DISTRIBUTION_DOMAIN="$(distribution_domain_by_id "${DISTRIBUTION_ID}")"

if [[ -n "${CUSTOM_DOMAIN}" ]]; then
  echo "[5/5] Creating Route 53 alias record..."
  upsert_alias_record "${HOSTED_ZONE_ID}" "${CUSTOM_DOMAIN}" "${DISTRIBUTION_DOMAIN}"
  echo
  echo "CloudFront front door is deployed."
  echo "  Distribution ID: ${DISTRIBUTION_ID}"
  echo "  CloudFront URL:  https://${DISTRIBUTION_DOMAIN}"
  echo "  Custom domain:   https://${CUSTOM_DOMAIN}"
else
  echo "[5/5] Custom domain not configured."
  echo
  echo "CloudFront front door is deployed."
  echo "  Distribution ID: ${DISTRIBUTION_ID}"
  echo "  URL:             https://${DISTRIBUTION_DOMAIN}"
fi
