#!/usr/bin/env bash
# Peuple le Network Volume avec des modèles, via le script embarqué dans l'image
# (/opt/scripts/download_models.py, config JSON + tags/id — voir scripts/models.json).
# Se connecte en SSH et lui transmet tous les arguments reçus ici.
#
# Usage:
#   ./07-download-models.sh                        # tag MODEL_TAGS de .env (defaut: turbo)
#   ./07-download-models.sh --tag hq                # un tag precis
#   ./07-download-models.sh --id lora-fl2v-8step     # un seul modele par id
#   ./07-download-models.sh --list                  # explorer les modeles/tags disponibles
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
  echo "   /opt/scripts/download_models.py ${VOLUME_MOUNT_PATH}/models --tag ${MODEL_TAGS:-turbo}" >&2
  exit 1
fi

# Sans argument : utilise MODEL_TAGS de .env (defaut turbo dans download_models.py lui-meme
# si meme cette variable est absente).
ARGS=("$@")
if [[ "$#" -eq 0 && -n "${MODEL_TAGS:-}" ]]; then
  ARGS=(--tag "${MODEL_TAGS}")
fi

echo ">> Connexion : ${SSH_CMD}"
# HF_TOKEN/CIVITAI_TOKEN passés explicitement : une session SSH n'hérite pas forcément
# des env définies au démarrage du pod (--env), selon la config PAM/sshd de l'image.
# shellcheck disable=SC2086
$SSH_CMD "HF_TOKEN=${HF_TOKEN:-} CIVITAI_TOKEN=${CIVITAI_TOKEN:-} /opt/scripts/download_models.py ${VOLUME_MOUNT_PATH}/models $(printf '%q ' "${ARGS[@]}")"
