#!/usr/bin/env bash
# Télécharge les poids MiniMax H3 sur le Network Volume RunPod.
#
# Par défaut : le "kit turbo" (léger, rapide) pour itérer sur les prompts :
#   - diffusion models FL2VA/Ref2VA en pruned + int8_convrot (les plus légers/rapides)
#   - text encoder en NVFP4 (pas besoin de matériel Blackwell spécifique, le plus petit)
#   - VAE vidéo/audio
#   - LoRA turbo (4 et 8 steps) : génération en quelques secondes pour valider un prompt
#     avant de lancer le rendu final avec les poids complets.
#
# Avec DOWNLOAD_FULL_QUALITY=1 : ajoute aussi les diffusion models non-pruned int8_convrot,
# à utiliser SANS la LoRA turbo, pour le rendu final en pleine qualité (plus lent).
#
# HF_TOKEN : lu automatiquement par huggingface_hub s'il est exporté dans l'environnement
# (voir deploy/env.example). Pas obligatoire pour les dépôts publics utilisés ici, mais
# évite le rate-limit anonyme et sera nécessaire si un dépôt devient gated.
# CIVITAI_TOKEN : câblé/propagé (deploy/env.example, 02-start-pod.sh, 07-download-models.sh)
# en prévision d'un futur script de téléchargement CivitAI ; non utilisé par ce script.
#
# Usage: download_models.sh [dossier_cible]   (defaut: /runpod-volume/models)
set -euo pipefail

MODELS_DIR="${1:-${MODELS_VOLUME_DIR:-/runpod-volume/models}}"
BASE_REPO="Comfy-Org/MiniMax-H3"
TURBO_REPO="drbaph/MiniMax-H3-Turbo-Lora-ComfyUI"

echo ">> Cible : ${MODELS_DIR}"
mkdir -p "${MODELS_DIR}"/{diffusion_models,text_encoders,vae,loras}

if [[ -n "${HF_TOKEN:-}" ]]; then
  echo ">> HF_TOKEN détecté, authentification Hugging Face activée."
else
  echo ">> Pas de HF_TOKEN : téléchargement anonyme (suffisant pour ces dépôts publics)."
fi

# huggingface_hub 2.0 a supprimé la commande "huggingface-cli" (remplacée par "hf") ET
# l'extra "hf_transfer" (Xet est désormais le mécanisme de transfert par défaut, plus besoin
# d'extra). On plafonne à <2.0 : c'est de toute façon la contrainte déjà posée par transformers/
# tokenizers (déjà installés par ComfyUI), donc ça évite aussi le conflit de dépendances pip.
# Pas de -U : si une version <2.0 satisfaisante est déjà installée, on ne touche à rien.
python -m pip install -q "huggingface_hub<2.0"

echo ">> [1/3] Kit turbo (int8_convrot pruned + text encoder NVFP4 + VAE) ~42 Go"
hf download "${BASE_REPO}" \
  diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors \
  diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors \
  text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors \
  vae/minimax_h3_video_vae_int8_convrot.safetensors \
  vae/minimax_h3_audio_vae_fp32.safetensors \
  --local-dir "${MODELS_DIR}"

echo ">> [2/3] LoRA turbo (test rapide de prompts, 4-8 steps)"
hf download "${TURBO_REPO}" \
  minimax_h3_fl2v_turbo_4step_v1.1_768p_comfyui_resized_avg_rank_64_bf16.safetensors \
  minimax_h3_ref2v_turbo_4step_v0.1_comfyui_resized_avg_rank_21_bf16.safetensors \
  minimax_h3_hyperflow_8step_v1.0_comfyui_pruned_bf16.safetensors \
  --local-dir "${MODELS_DIR}/loras"

if [[ "${DOWNLOAD_FULL_QUALITY:-0}" == "1" ]]; then
  echo ">> [3/3] Poids qualité maximale (non-pruned, sans LoRA) ~+40 Go"
  hf download "${BASE_REPO}" \
    diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors \
    diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors \
    --local-dir "${MODELS_DIR}"
else
  echo ">> [3/3] Ignoré (DOWNLOAD_FULL_QUALITY=0). Relance avec DOWNLOAD_FULL_QUALITY=1 pour"
  echo "   ajouter les poids de rendu final pleine qualité."
fi

echo ">> Terminé. Contenu de ${MODELS_DIR} :"
du -sh "${MODELS_DIR}"/* 2>/dev/null || true
