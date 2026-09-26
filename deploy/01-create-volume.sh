#!/usr/bin/env bash
# Crée le Network Volume qui stockera les modèles MiniMax H3 (persiste entre les pods).
# À lancer une seule fois. Le VOLUME_ID est écrit dans deploy/.env.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ -n "${VOLUME_ID:-}" ]]; then
  echo ">> VOLUME_ID déjà défini (${VOLUME_ID}) dans .env, rien à faire."
  exit 0
fi

echo ">> Création du volume '${POD_NAME}-models' (${VOLUME_SIZE_GB} Go, ${DATA_CENTER_ID})"
OUT=$(runpodctl network-volume create \
  --name "${POD_NAME}-models" \
  --size "${VOLUME_SIZE_GB}" \
  --data-center-id "${DATA_CENTER_ID}" \
  -o json)

echo "$OUT"
NEW_ID=$(echo "$OUT" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

if [[ -z "$NEW_ID" ]]; then
  echo "!! Impossible d'extraire l'ID du volume depuis la sortie ci-dessus. Reporte-le manuellement dans deploy/.env (VOLUME_ID=...)." >&2
  exit 1
fi

save_env_var VOLUME_ID "$NEW_ID"
echo ">> VOLUME_ID=${NEW_ID} enregistré dans deploy/.env"
echo ">> Important : ton pod devra être créé dans le MÊME data-center (${DATA_CENTER_ID}) que ce volume."
