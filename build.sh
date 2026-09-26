#!/usr/bin/env bash
# Construit l'image ComfyUI par-dessus runpod-blackwell-base.
# BASE_IMAGE doit pointer vers une image déjà construite/poussée par ../runpod-blackwell-base.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE_NAME="${IMAGE_NAME:-runpod-comfy-blackwell}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
BASE_IMAGE="${BASE_IMAGE:-runpod-blackwell-base:latest}"
COMFYUI_VERSION="${COMFYUI_VERSION:-v0.37.2}"
REGISTRY="${REGISTRY:-}"

FULL_TAG="${IMAGE_NAME}:${IMAGE_TAG}"
[[ -n "$REGISTRY" ]] && FULL_TAG="${REGISTRY}/${FULL_TAG}"

echo ">> Build ${FULL_TAG} (base=${BASE_IMAGE}, comfyui=${COMFYUI_VERSION})"
docker buildx build \
  --platform linux/amd64 \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "COMFYUI_VERSION=${COMFYUI_VERSION}" \
  --tag "${FULL_TAG}" \
  --load \
  .

echo
docker images "${IMAGE_NAME}" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
