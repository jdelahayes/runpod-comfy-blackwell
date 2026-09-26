#!/usr/bin/env bash
# À lancer une fois après la création du pod (si MODELS_AUTO_DOWNLOAD=0) pour peupler le
# Network Volume avec les poids MiniMax H3. Se connecte en SSH et exécute le script embarqué
# dans l'image (/opt/scripts/download_models.sh).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
: "${POD_ID:?Aucun POD_ID dans .env}"

SSH_CMD=$(runpodctl ssh connect "$POD_ID" | grep -Eo '^ssh [^"]*' | head -1 || true)
if [[ -z "$SSH_CMD" ]]; then
  echo "!! Impossible de récupérer la commande SSH automatiquement." >&2
  echo "   Lance ./06-ssh.sh, connecte-toi, puis exécute manuellement :" >&2
  echo "   DOWNLOAD_FULL_QUALITY=${DOWNLOAD_FULL_QUALITY} /opt/scripts/download_models.sh ${VOLUME_MOUNT_PATH}/models" >&2
  exit 1
fi

echo ">> Connexion : ${SSH_CMD}"
$SSH_CMD "DOWNLOAD_FULL_QUALITY=${DOWNLOAD_FULL_QUALITY} /opt/scripts/download_models.sh ${VOLUME_MOUNT_PATH}/models"
