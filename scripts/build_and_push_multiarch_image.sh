#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPOSITORY="${ECR_REPOSITORY:-mini-load-balancer}"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d%H%M%S)}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
PUSH_LATEST="${PUSH_LATEST:-false}"
BUILDX_BUILDER="${BUILDX_BUILDER:-minilb-multiarch}"

AWS_CMD=(aws --region "${AWS_REGION}")
if [[ -n "${AWS_PROFILE:-}" ]]; then
  AWS_CMD+=(--profile "${AWS_PROFILE}")
fi

AWS_ACCOUNT_ID="$("${AWS_CMD[@]}" sts get-caller-identity --query Account --output text)"
REPOSITORY_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}"

if ! docker buildx inspect "${BUILDX_BUILDER}" >/dev/null 2>&1; then
  docker buildx create --name "${BUILDX_BUILDER}" --driver docker-container --use >/dev/null
else
  docker buildx use "${BUILDX_BUILDER}" >/dev/null
fi

docker buildx inspect --bootstrap >/dev/null
"${AWS_CMD[@]}" ecr get-login-password | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" >/dev/null

build_tags=(-t "${REPOSITORY_URI}:${IMAGE_TAG}")
if [[ "${PUSH_LATEST}" == "true" ]]; then
  build_tags+=(-t "${REPOSITORY_URI}:latest")
fi

docker buildx build \
  --platform "${PLATFORMS}" \
  "${build_tags[@]}" \
  --push \
  .

echo "Pushed ${REPOSITORY_URI}:${IMAGE_TAG}"
docker buildx imagetools inspect "${REPOSITORY_URI}:${IMAGE_TAG}"
