#!/usr/bin/env bash
# Affiche/lance la commande SSH pour se connecter au pod (nécessite une clé SSH ajoutée
# à ton compte RunPod, cf. https://docs.runpod.io/pods/configuration/use-ssh).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
: "${POD_ID:?Aucun POD_ID dans .env}"
runpodctl ssh connect "$POD_ID"
