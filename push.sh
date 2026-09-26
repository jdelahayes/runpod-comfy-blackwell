#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE_NAME="${IMAGE_NAME:-runpod-comfy-blackwell}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
: "${REGISTRY:?Définis REGISTRY, ex: export REGISTRY=ghcr.io/tonuser}"

FULL_TAG="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${FULL_TAG}"
docker push "${FULL_TAG}"
echo ">> Poussé : ${FULL_TAG}"
