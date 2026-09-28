#!/usr/bin/env bash
# Point d'entrée du pod : démarre SSH (standard RunPod) et JupyterLab, installe ce qui manque
# pour les profils de COMFY_PROFILES (modèles, custom nodes, ... — voir scripts/profiles.json),
# place models/, input/, output/ et user/ sur le Network Volume, puis lance ComfyUI.
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

# --- Persistance sur le Network Volume ---
# ComfyUI/models, input, output et user deviennent chacun un lien vers le volume
# (/runpod-volume/{models,input,output,user}) : tout ce qui y est écrit est persisté, y compris les
# sous-dossiers créés à la volée par des custom nodes (ex. models/refmods pour MiniMax H3), et
# user/ (workflows enregistrés, réglages ComfyUI, config du Manager).
# Le contenu local éventuel (ex. models/configs/*.yaml ou input/example.png livrés par ComfyUI)
# est d'abord copié sur le volume, sans écraser l'existant. Les fichiers vides "put_*_here" et
# les liens symboliques (ancien schéma : un lien par sous-dossier de models/) sont ignorés.
link_to_volume() {
  local local_dir="$1" volume_dir="$2"
  [[ -L "$local_dir" ]] && return
  mkdir -p "$volume_dir"
  if [[ -d "$local_dir" ]]; then
    find "$local_dir" -mindepth 1 -maxdepth 1 ! -name 'put_*_here' ! -type l \
      -exec cp -a --update=none {} "${volume_dir}/" \;
    find "$volume_dir" -mindepth 2 -maxdepth 2 -type f -empty -name 'put_*_here' -delete
    rm -rf "$local_dir"
  fi
  ln -s "$volume_dir" "$local_dir"
  echo ">> ${local_dir} -> ${volume_dir}"
}

link_volume_dirs() {
  local mount_point
  mount_point="$(dirname "$MODELS_VOLUME_DIR")"
  # On teste le point de montage (ex: /runpod-volume), pas MODELS_VOLUME_DIR lui-même : sur un
  # volume neuf, le sous-dossier models/ n'existe pas encore.
  if [[ ! -d "$mount_point" ]]; then
    echo ">> Aucun Network Volume monté sur ${mount_point} : models/, input/, output/ et user/"
    echo ">> locaux au conteneur (perdus à sa suppression)."
    return
  fi
  link_to_volume "${COMFY_HOME}/models" "$MODELS_VOLUME_DIR"
  link_to_volume "${COMFY_HOME}/input" "${mount_point}/input"
  link_to_volume "${COMFY_HOME}/output" "${mount_point}/output"
  link_to_volume "${COMFY_HOME}/user" "${mount_point}/user"
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

# Rend les tokens et la config des profils visibles dans les futures sessions SSH (une session
# ouverte via sshd n'hérite ni de l'environnement du conteneur passé par --env, ni des ENV de
# l'image, seulement de ce qui est écrit dans /etc/environment, lu par pam_env). Utile pour
# lancer /opt/scripts/comfy_profiles.py à la main ou via deploy/07-sync-profiles.sh.
persist_env() {
  for var in HF_TOKEN CIVITAI_TOKEN JUPYTER_TOKEN COMFY_HOME MODELS_VOLUME_DIR COMFY_PROFILES COMFY_PROFILES_CONFIG; do
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
persist_env
setup_jupyter
link_volume_dirs

# Installe ce qui manque pour les profils demandés (après link_volume_dirs : modèles et workflows
# sont ainsi écrits directement sur le volume), avant de lancer ComfyUI (qui doit voir les
# nouveaux custom nodes). Long au premier démarrage sur un volume vide.
if [[ -n "${COMFY_PROFILES:-}" ]]; then
  echo ">> Synchronisation des profils : ${COMFY_PROFILES}"
  /opt/scripts/comfy_profiles.py sync \
    || echo ">> Synchronisation incomplète (voir ci-dessus), on démarre quand même."
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
