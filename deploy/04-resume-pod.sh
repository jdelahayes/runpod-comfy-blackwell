#!/usr/bin/env bash
# Redémarre un pod stoppé (rapide : pas de re-pull d'image ni de re-téléchargement de modèles).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
: "${POD_ID:?Aucun POD_ID dans .env}"
runpodctl pod start "$POD_ID"
