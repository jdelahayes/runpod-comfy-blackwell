#!/usr/bin/env bash
# À lancer une fois après la création du pod (si MODELS_AUTO_DOWNLOAD=0) pour peupler le
# Network Volume avec les poids MiniMax H3. Se connecte en SSH et exécute le script embarqué
# dans l'image (/opt/scripts/download_models.sh).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
: "${POD_ID:?Aucun POD_ID dans .env}"

command -v jq >/dev/null 2>&1 || {
  echo "!! jq est requis par ce script. Installe-le (apt install jq / brew install jq)." >&2
  exit 1
}

# `runpodctl ssh connect` est déprécié ; `ssh info` le remplace mais ne se connecte pas
# elle-même (juste les infos), donc on exécute nous-mêmes la commande ssh retournée.
SSH_CMD=$(runpodctl ssh info "$POD_ID" -o json | jq -r '.ssh_command // empty')
if [[ -z "$SSH_CMD" ]]; then
  echo "!! Impossible de récupérer la commande SSH automatiquement (runpodctl ssh info)." >&2
  echo "   Lance ./06-ssh.sh, connecte-toi, puis exécute manuellement :" >&2
  echo "   DOWNLOAD_FULL_QUALITY=${DOWNLOAD_FULL_QUALITY} /opt/scripts/download_models.sh ${VOLUME_MOUNT_PATH}/models" >&2
  exit 1
fi

echo ">> Connexion : ${SSH_CMD}"
# HF_TOKEN/CIVITAI_TOKEN passés explicitement : une session SSH n'hérite pas forcément
# des env définies au démarrage du pod (--env), selon la config PAM/sshd de l'image.
# shellcheck disable=SC2086
$SSH_CMD "DOWNLOAD_FULL_QUALITY=${DOWNLOAD_FULL_QUALITY} HF_TOKEN=${HF_TOKEN:-} CIVITAI_TOKEN=${CIVITAI_TOKEN:-} /opt/scripts/download_models.sh ${VOLUME_MOUNT_PATH}/models"
