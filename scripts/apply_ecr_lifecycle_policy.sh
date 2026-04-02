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
ECR_REPOSITORY="${ECR_REPOSITORY:-mini-load-balancer}"
KEEP_TAGGED_COUNT="${KEEP_TAGGED_COUNT:-8}"
UNTAGGED_EXPIRY_DAYS="${UNTAGGED_EXPIRY_DAYS:-7}"
TAG_PREFIX="${TAG_PREFIX:-20}"

AWS_ARGS=(--region "${AWS_REGION}" --no-cli-pager)
if [[ -n "${AWS_PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${AWS_PROFILE}")
fi

aws_cli() {
  "${AWS_BIN}" "${AWS_ARGS[@]}" "$@"
}

POLICY_TEXT="$(cat <<JSON
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Expire untagged images older than ${UNTAGGED_EXPIRY_DAYS} days",
      "selection": {
        "tagStatus": "untagged",
        "countType": "sinceImagePushed",
        "countUnit": "days",
        "countNumber": ${UNTAGGED_EXPIRY_DAYS}
      },
      "action": {
        "type": "expire"
      }
    },
    {
      "rulePriority": 2,
      "description": "Keep only the latest ${KEEP_TAGGED_COUNT} timestamp-tagged images",
      "selection": {
        "tagStatus": "tagged",
        "tagPrefixList": ["${TAG_PREFIX}"],
        "countType": "imageCountMoreThan",
        "countNumber": ${KEEP_TAGGED_COUNT}
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}
JSON
)"

aws_cli ecr put-lifecycle-policy \
  --repository-name "${ECR_REPOSITORY}" \
  --lifecycle-policy-text "${POLICY_TEXT}" >/dev/null

echo "Applied lifecycle policy to ${ECR_REPOSITORY}."
echo "- Keep tagged images with prefix ${TAG_PREFIX}: ${KEEP_TAGGED_COUNT}"
echo "- Expire untagged images after: ${UNTAGGED_EXPIRY_DAYS} days"
