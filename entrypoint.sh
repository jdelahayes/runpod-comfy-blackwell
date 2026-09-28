#!/usr/bin/env bash
# Point d'entrée du pod : lie les modèles depuis le Network Volume, démarre SSH (standard
# RunPod) puis ComfyUI. Ne télécharge jamais de modèles lui-même (voir scripts/download_models.sh
# et deploy/07-download-models.sh) pour ne pas ralentir chaque redémarrage de pod.
set -euo pipefail

COMFY_HOME="${COMFY_HOME:-/workspace/ComfyUI}"
MODELS_VOLUME_DIR="${MODELS_VOLUME_DIR:-/runpod-volume/models}"

# Derrière le proxy RunPod (https://<pod-id>-<port>.proxy.runpod.net), le Host vu par le
# conteneur ne correspond pas à l'IP interne : ComfyUI (et Jupyter) rejettent ça par défaut
# ("request with non matching host and origin", 403). RUNPOD_POD_ID est injecté automatiquement
# par RunPod sur chaque pod : on construit l'origine exacte à partir de là. En dehors de RunPod
# (tests locaux), on retombe sur un wildcard.
proxy_origin() {
  local port="$1"
  if [[ -n "${RUNPOD_POD_ID:-}" ]]; then
    echo "https://${RUNPOD_POD_ID}-${port}.proxy.runpod.net"
  else
    echo "*"
  fi
}

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
  local mount_point
  mount_point="$(dirname "$MODELS_VOLUME_DIR")"
  # On teste le point de montage (ex: /runpod-volume), pas MODELS_VOLUME_DIR lui-même : sur un
  # volume neuf, le sous-dossier models/ n'existe pas encore et ne sera jamais créé si on
  # bloque ici (bug vécu : ComfyUI démarrait alors avec ses dossiers models/ locaux vides,
  # jamais remplacés par les liens symboliques, même après un téléchargement sur le volume).
  if [[ ! -d "$mount_point" ]]; then
    echo ">> Aucun Network Volume monté sur ${mount_point}."
    echo ">> Les dossiers models/ de ComfyUI resteront vides tant qu'aucun modèle n'y est copié."
    return
  fi
  mkdir -p "$MODELS_VOLUME_DIR"

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

# --- JupyterLab (arrière-plan, lancé avant le exec final vers ComfyUI) ---
setup_jupyter() {
  local token="${JUPYTER_TOKEN:-}"
  if [[ -z "$token" ]]; then
    token=$(python -c 'import secrets; print(secrets.token_hex(16))')
    echo ">> JUPYTER_TOKEN non défini, token généré pour cette session : ${token}"
    echo "   (fixe le secret RunPod jupyter_token pour un token stable entre redémarrages)"
  fi
  local origin
  origin=$(proxy_origin 8888)
  mkdir -p /workspace /root/.local/share/jupyter/runtime
  # SHELL n'est pas exporté par défaut dans un conteneur Docker. jupyter_server_terminals
  # (terminado) s'en sert pour choisir le shell du terminal web ; sans ça il retombe sur un
  # shell minimal sans historique ni auto-complétion. root a bien /bin/bash comme shell par
  # défaut (/etc/passwd) mais ça ne suffit pas, terminado regarde $SHELL en priorité.
  export SHELL=/bin/bash
  nohup jupyter lab \
    --ip=0.0.0.0 --port=8888 --no-browser --allow-root \
    --IdentityProvider.token="${token}" \
    --ServerApp.allow_origin="${origin}" \
    --ServerApp.root_dir=/workspace \
    > /workspace/jupyter.log 2>&1 &
  echo ">> JupyterLab démarré sur le port 8888 (logs : /workspace/jupyter.log)"
}

# Rend HF_TOKEN/CIVITAI_TOKEN visibles dans les futures sessions SSH interactives (une
# session ouverte via sshd n'hérite pas de l'environnement du conteneur passé par --env,
# seulement de ce qui est écrit dans /etc/environment, lu par pam_env).
persist_tokens() {
  for var in HF_TOKEN CIVITAI_TOKEN JUPYTER_TOKEN; do
    if [[ -n "${!var:-}" ]]; then
      sed -i "/^${var}=/d" /etc/environment
      echo "${var}=${!var}" >> /etc/environment
    fi
  done
}

# Même problème que les tokens ci-dessus, mais pour PATH : /etc/environment d'Ubuntu ne
# contient qu'un PATH système par défaut, sans /opt/venv/bin. Sans ça, une session SSH (ou
# une commande exécutée via `ssh pod "commande"`) ne trouve ni python, ni pip, ni hf, ni uv.
persist_path() {
  local base_path
  base_path=$(sed -nE 's/^PATH="?([^"]*)"?$/\1/p' /etc/environment)
  base_path="${base_path:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin}"
  if [[ "$base_path" != *"/opt/venv/bin"* ]]; then
    sed -i '/^PATH=/d' /etc/environment
    echo "PATH=\"/opt/venv/bin:${base_path}\"" >> /etc/environment
  fi
}

setup_ssh
persist_path
persist_tokens
link_models
setup_jupyter

if [[ "${MODELS_AUTO_DOWNLOAD:-0}" == "1" ]]; then
  echo ">> MODELS_AUTO_DOWNLOAD=1 : téléchargement des modèles (tags: ${MODEL_TAGS:-turbo})..."
  /opt/scripts/download_models.py "$MODELS_VOLUME_DIR" --tag "${MODEL_TAGS:-turbo}" \
    || echo ">> Téléchargement échoué, on démarre quand même."
fi

# Une commande explicite (ex: `docker run image bash`, utile pour inspecter/debugger le
# conteneur) prend le pas sur le démarrage par défaut de ComfyUI.
if [[ "$#" -gt 0 ]]; then
  exec "$@"
fi

cd "$COMFY_HOME"
COMFY_ORIGIN=$(proxy_origin 8188)
echo ">> Démarrage de ComfyUI sur le port 8188 (CORS/host autorisé pour ${COMFY_ORIGIN})"
exec python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header "${COMFY_ORIGIN}" --enable-manager ${COMFY_EXTRA_ARGS:-}
