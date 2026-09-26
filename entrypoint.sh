#!/usr/bin/env bash
# Point d'entrée du pod : lie les modèles depuis le Network Volume, démarre SSH (standard
# RunPod) puis ComfyUI. Ne télécharge jamais de modèles lui-même (voir scripts/download_models.sh
# et deploy/07-download-models.sh) pour ne pas ralentir chaque redémarrage de pod.
set -euo pipefail

COMFY_HOME="${COMFY_HOME:-/workspace/ComfyUI}"
MODELS_VOLUME_DIR="${MODELS_VOLUME_DIR:-/runpod-volume/models}"

# --- SSH (pattern standard RunPod) ---
setup_ssh() {
  mkdir -p /var/run/sshd ~/.ssh
  chmod 700 ~/.ssh
  if [[ -n "${PUBLIC_KEY:-}" ]]; then
    echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
  fi
  ssh-keygen -A
  /usr/sbin/sshd
}

# --- Lien des modèles depuis le Network Volume ---
link_models() {
  if [[ ! -d "$MODELS_VOLUME_DIR" ]]; then
    echo ">> Aucun Network Volume monté sur ${MODELS_VOLUME_DIR}."
    echo ">> Les dossiers models/ de ComfyUI resteront vides tant qu'aucun modèle n'y est copié."
    return
  fi

  for sub in diffusion_models text_encoders vae loras embeddings model_patches checkpoints; do
    mkdir -p "${MODELS_VOLUME_DIR}/${sub}"
    target="${COMFY_HOME}/models/${sub}"
    if [[ -L "$target" ]]; then
      continue
    fi
    rm -rf "$target"
    ln -s "${MODELS_VOLUME_DIR}/${sub}" "$target"
    echo ">> ${target} -> ${MODELS_VOLUME_DIR}/${sub}"
  done
}

setup_ssh
link_models

if [[ "${MODELS_AUTO_DOWNLOAD:-0}" == "1" ]]; then
  echo ">> MODELS_AUTO_DOWNLOAD=1 : téléchargement des poids MiniMax H3 manquants..."
  /opt/scripts/download_models.sh "$MODELS_VOLUME_DIR" || echo ">> Téléchargement échoué, on démarre quand même."
fi

# Une commande explicite (ex: `docker run image bash`, utile pour inspecter/debugger le
# conteneur) prend le pas sur le démarrage par défaut de ComfyUI.
if [[ "$#" -gt 0 ]]; then
  exec "$@"
fi

cd "$COMFY_HOME"
echo ">> Démarrage de ComfyUI sur le port 8188"
exec python main.py --listen 0.0.0.0 --port 8188 ${COMFY_EXTRA_ARGS:-}
