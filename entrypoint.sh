#!/usr/bin/env bash
# Point d'entrée du pod : démarre SSH (standard RunPod) et JupyterLab, installe ce qui manque
# pour les profils de COMFY_PROFILES (modèles, custom nodes, ... — fichier récupéré depuis
# COMFY_PROFILES_URL),
# place models/, input/, output/ et user/ sur le Network Volume, puis lance ComfyUI.
set -euo pipefail

COMFY_HOME="${COMFY_HOME:-/workspace/ComfyUI}"
MODELS_VOLUME_DIR="${MODELS_VOLUME_DIR:-/runpod-volume/models}"
COMFY_PROFILES_SEED="${COMFY_PROFILES_SEED:-/opt/scripts/profiles.json}"
# Vide (ex. passé vide par le template) = URL par défaut.
COMFY_PROFILES_URL="${COMFY_PROFILES_URL:-https://github.com/jdelahayes/comfyui-profiles-repo/raw/refs/heads/main/profiles.json}"
export COMFY_PROFILES_SEED COMFY_PROFILES_URL

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
  # Custom nodes des profils clonés sur le volume et liés dans custom_nodes/ (ceux de l'image,
  # de vrais dossiers dans custom_nodes/, ne sont jamais touchés par le gestionnaire).
  export COMFY_PROFILES_NODES_STORE="${COMFY_PROFILES_NODES_STORE:-${mount_point}/custom_nodes}"
  link_to_volume "${COMFY_HOME}/models" "$MODELS_VOLUME_DIR"
  link_to_volume "${COMFY_HOME}/input" "${mount_point}/input"
  link_to_volume "${COMFY_HOME}/output" "${mount_point}/output"
  link_to_volume "${COMFY_HOME}/user" "${mount_point}/user"
}

# --- Modèle de profils (COMFY_PROFILES_SEED), récupéré à chaque démarrage ---
# profiles.json n'est pas dans l'image : il est téléchargé depuis COMFY_PROFILES_URL (dépôt
# GitHub) et validé (JSON) avant de remplacer le modèle. Une copie est gardée sur le Network
# Volume ; si le téléchargement échoue (GitHub injoignable, URL erronée...), on repart d'elle.
fetch_profiles_seed() {
  local mount_point cache tmp
  mount_point="$(dirname "$MODELS_VOLUME_DIR")"
  cache="${mount_point}/cache/profiles.json"
  mkdir -p "$(dirname "$COMFY_PROFILES_SEED")"
  tmp="$(mktemp)"
  echo ">> Récupération des profils : ${COMFY_PROFILES_URL}"
  if python - "$COMFY_PROFILES_URL" "$tmp" <<'PY'
import json, sys, urllib.request
url, dest = sys.argv[1:3]
try:
    with urllib.request.urlopen(url, timeout=30) as resp:
        data = resp.read()
    json.loads(data)
except Exception as e:  # message court : l'appelant se replie sur la copie du volume
    sys.exit(f">> {url} : {e}")
with open(dest, "wb") as f:
    f.write(data)
PY
  then
    mv "$tmp" "$COMFY_PROFILES_SEED"
    chmod 644 "$COMFY_PROFILES_SEED"
    if [[ -d "$mount_point" ]]; then
      mkdir -p "$(dirname "$cache")"
      cp "$COMFY_PROFILES_SEED" "$cache"
    fi
  else
    rm -f "$tmp"
    if [[ -f "$cache" ]]; then
      echo ">> Échec du téléchargement : copie du volume utilisée (${cache})."
      cp "$cache" "$COMFY_PROFILES_SEED"
    else
      echo ">> Échec du téléchargement et aucune copie sur le volume : pas de modèle de profils."
    fi
  fi
}

# --- comfyui-profiles (panneau Profils et gestionnaire), installé à chaque démarrage ---
# Pas dans l'image : une nouvelle version du plugin n'oblige pas à la reconstruire. Cloné à la
# version COMFYUI_PROFILES_REF (tag ou branche ; "latest" = dernier tag vX.Y.Z publié), sur le
# Network Volume quand il y en a un (hors de COMFY_PROFILES_NODES_STORE : ce n'est pas un node
# géré par les profils), puis lié dans custom_nodes/ et en /opt/scripts. Si GitHub est
# injoignable, la copie déjà présente sert telle quelle.
install_profiles_plugin() {
  local repo="${COMFYUI_PROFILES_REPO:-https://github.com/jdelahayes/comfyui-profiles.git}"
  local ref="${COMFYUI_PROFILES_REF:-latest}"
  local mount_point dest
  mount_point="$(dirname "$MODELS_VOLUME_DIR")"
  if [[ -d "$mount_point" ]]; then
    dest="${mount_point}/comfyui-profiles"
  else
    dest=/opt/comfyui-profiles
  fi

  if [[ "$ref" == latest ]]; then
    ref=$(timeout 30 git ls-remote --tags --refs "$repo" 'v*' 2>/dev/null \
            | sed 's|.*refs/tags/||' | sort -V | tail -n 1) || true
  fi
  echo ">> comfyui-profiles : ${ref:-version inconnue (GitHub injoignable ?)} -> ${dest}"
  if [[ -n "$ref" ]]; then
    if [[ -d "${dest}/.git" ]]; then
      if ! { timeout 120 git -C "$dest" fetch -q --depth 1 origin "$ref" \
             && git -C "$dest" checkout -q -f --detach FETCH_HEAD; }; then
        echo ">> Échec de la mise à jour de comfyui-profiles : copie existante utilisée."
      fi
    else
      rm -rf "${dest}.tmp"
      if timeout 120 git -c advice.detachedHead=false clone -q --depth 1 --branch "$ref" "$repo" "${dest}.tmp"; then
        rm -rf "$dest"
        mv "${dest}.tmp" "$dest"
      else
        rm -rf "${dest}.tmp"
        echo ">> Échec du clone de comfyui-profiles (${ref})."
      fi
    fi
  fi
  if [[ ! -d "${dest}/.git" ]]; then
    echo ">> comfyui-profiles absent : ComfyUI démarre sans panneau Profils ni synchronisation."
    return 0
  fi
  # Clone superficiel : le tag récupéré par fetch n'est pas toujours une référence locale.
  echo ">> comfyui-profiles ${ref:-(copie existante)} : $(git -C "$dest" log -1 --format='%h %s' 2>/dev/null)"
  # Un vrai dossier à cet endroit (image d'avant ce mécanisme) : ln y créerait le lien dedans.
  local link="${COMFY_HOME}/custom_nodes/comfyui-profiles"
  [[ -d "$link" && ! -L "$link" ]] && rm -rf "$link"
  ln -sfn "$dest" "$link"
  mkdir -p /opt/scripts
  ln -sfn "${dest}/comfy_profiles.py" /opt/scripts/comfy_profiles.py
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
  for var in HF_TOKEN CIVITAI_TOKEN JUPYTER_TOKEN GDRIVE_ZIP_PASSWORD COMFY_HOME MODELS_VOLUME_DIR \
             COMFY_PROFILES COMFY_PROFILES_CONFIG COMFY_PROFILES_SEED COMFY_PROFILES_URL \
             COMFY_PROFILES_NODES_STORE COMFYUI_PROFILES_REF; do
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
# Avant persist_env et JupyterLab : définit COMFY_PROFILES_NODES_STORE quand un volume est monté.
link_volume_dirs
install_profiles_plugin
fetch_profiles_seed
persist_env
setup_jupyter

# Installe ce qui manque pour les profils demandés (après link_volume_dirs : modèles et workflows
# sont ainsi écrits directement sur le volume), avant de lancer ComfyUI (qui doit voir les
# nouveaux custom nodes). Long au premier démarrage sur un volume vide.
if [[ -n "${COMFY_PROFILES:-}" && ! -e /opt/scripts/comfy_profiles.py ]]; then
  echo ">> Profils ${COMFY_PROFILES} non synchronisés : comfyui-profiles absent."
elif [[ -n "${COMFY_PROFILES:-}" ]]; then
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
