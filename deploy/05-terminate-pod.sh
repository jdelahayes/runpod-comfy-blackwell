#!/usr/bin/env bash
# Supprime définitivement le pod (le disque conteneur est perdu ; le Network Volume survit).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
: "${POD_ID:?Aucun POD_ID dans .env}"

read -r -p "Supprimer définitivement le pod ${POD_ID} (${POD_NAME}) ? [y/N] " confirm
[[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "Annulé."; exit 0; }

runpodctl pod delete "$POD_ID"
save_env_var POD_ID ""
echo ">> Pod supprimé. Le Network Volume (${VOLUME_ID}) est conservé."
