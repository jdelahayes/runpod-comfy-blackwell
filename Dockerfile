# syntax=docker/dockerfile:1.7
#
# runpod-comfy-blackwell
# ComfyUI (dernière stable) sur runpod-blackwell-base. Aucun poids de modèle dans l'image :
# ils vivent sur un Network Volume RunPod monté au démarrage (voir ../deploy et scripts/).
# C'est ce qui garde l'image légère et le pull rapide à la création du pod.
ARG BASE_IMAGE=runpod-blackwell-base:latest
ARG COMFYUI_VERSION=v0.40.0
# Panneau « Profils » et gestionnaire de profils (comfy_profiles.py) : dépôt séparé, version fixée.
ARG COMFYUI_PROFILES_VERSION=v0.1.0

FROM ${BASE_IMAGE}
ARG COMFYUI_VERSION
ARG COMFYUI_PROFILES_VERSION

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

# manager_requirements.txt : dépendances du Manager intégré à ComfyUI (gestion des custom
# nodes depuis l'UI), activé au lancement par --enable-manager (voir entrypoint.sh).
RUN git clone --branch "${COMFYUI_VERSION}" --depth 1 \
      https://github.com/Comfy-Org/ComfyUI.git "${COMFY_HOME}" \
    && uv pip install --no-cache-dir -r "${COMFY_HOME}/requirements.txt" \
    && uv pip install --no-cache-dir -r "${COMFY_HOME}/manager_requirements.txt"

# JupyterLab : accès fichiers/terminal/notebooks sur le pod, en plus de ComfyUI.
RUN uv pip install --no-cache-dir jupyterlab

# pyzipper : extraction des zips chiffrés en AES (custom nodes "gdrive" des profils).
RUN uv pip install --no-cache-dir pyzipper

RUN find /opt/venv -type d -name "__pycache__" -prune -exec rm -rf {} +

# Profils d'utilisation (modèles, custom nodes, workflows...) : voir README.md, section Profils.
# Le gestionnaire vient du custom node comfyui-profiles (panneau Profils dans l'UI) ; le lien
# dans /opt/scripts garde le chemin utilisé par entrypoint.sh, 07-sync-profiles.py et
# profile_sizes.py (qui l'importe).
RUN git clone --branch "${COMFYUI_PROFILES_VERSION}" --depth 1 \
      https://github.com/jdelahayes/comfyui-profiles.git "${COMFY_HOME}/custom_nodes/comfyui-profiles" \
    && mkdir -p /opt/scripts \
    && ln -s "${COMFY_HOME}/custom_nodes/comfyui-profiles/comfy_profiles.py" /opt/scripts/comfy_profiles.py

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/profile_sizes.py /opt/scripts/profile_sizes.py
COPY scripts/profiles.json /opt/scripts/profiles.json
RUN chmod +x /usr/local/bin/entrypoint.sh /opt/scripts/comfy_profiles.py /opt/scripts/profile_sizes.py

EXPOSE 8188 8888 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
