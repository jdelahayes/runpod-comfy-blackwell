#!/usr/bin/env bash
# Ouvre une session SSH interactive sur le pod (nécessite une clé SSH ajoutée à ton compte
# RunPod, cf. https://docs.runpod.io/pods/configuration/use-ssh).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
: "${POD_ID:?Aucun POD_ID dans .env}"

command -v jq >/dev/null 2>&1 || {
  echo "!! jq est requis par ce script. Installe-le (apt install jq / brew install jq)." >&2
  exit 1
}

# `runpodctl ssh connect` est déprécié ; `ssh info` le remplace mais ne fait QUE renvoyer les
# infos de connexion (elle ne se connecte pas elle-même) — on exécute donc nous-mêmes la
# commande ssh qu'elle retourne.
SSH_CMD=$(runpodctl ssh info "$POD_ID" -o json | jq -r '.ssh_command // empty')
if [[ -z "$SSH_CMD" ]]; then
  echo "!! Impossible de récupérer la commande SSH (runpodctl ssh info)." >&2
  exit 1
fi

echo ">> ${SSH_CMD}"
# shellcheck disable=SC2086
exec $SSH_CMD
