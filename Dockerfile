# syntax=docker/dockerfile:1.7
#
# runpod-comfy-blackwell
# ComfyUI (dernière stable) sur runpod-blackwell-base. Aucun poids de modèle dans l'image :
# ils vivent sur un Network Volume RunPod monté au démarrage (voir ../deploy et scripts/).
# C'est ce qui garde l'image légère et le pull rapide à la création du pod.
ARG BASE_IMAGE=runpod-blackwell-base:latest
ARG COMFYUI_VERSION=v0.37.2

FROM ${BASE_IMAGE}
ARG COMFYUI_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    COMFY_HOME=/workspace/ComfyUI \
    MODELS_VOLUME_DIR=/runpod-volume/models

# ffmpeg : requis par les nodes vidéo (mux audio/vidéo, sortie MiniMax H3).
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

RUN git clone --branch "${COMFYUI_VERSION}" --depth 1 \
      https://github.com/Comfy-Org/ComfyUI.git "${COMFY_HOME}" \
    && uv pip install --no-cache-dir -r "${COMFY_HOME}/requirements.txt"

# ComfyUI-Manager : gestion des custom nodes depuis l'UI.
RUN git clone --depth 1 https://github.com/Comfy-Org/ComfyUI-Manager.git \
      "${COMFY_HOME}/custom_nodes/ComfyUI-Manager" \
    && uv pip install --no-cache-dir -r "${COMFY_HOME}/custom_nodes/ComfyUI-Manager/requirements.txt"

# KJNodes : fournit le node "Patch Sage Attention KJ" (doc ComfyUI, ~2x sur MiniMax H3).
RUN git clone --depth 1 https://github.com/kijai/ComfyUI-KJNodes.git \
      "${COMFY_HOME}/custom_nodes/ComfyUI-KJNodes" \
    && uv pip install --no-cache-dir -r "${COMFY_HOME}/custom_nodes/ComfyUI-KJNodes/requirements.txt" || true

RUN find /opt/venv -type d -name "__pycache__" -prune -exec rm -rf {} +

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/download_models.sh /opt/scripts/download_models.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /opt/scripts/download_models.sh

EXPOSE 8188 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
