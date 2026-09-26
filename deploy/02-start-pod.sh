#!/usr/bin/env bash
# Crée le pod ComfyUI/MiniMax H3 sur une RTX PRO 6000, avec le Network Volume monté.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${VOLUME_ID:?Lance 01-create-volume.sh avant celui-ci, ou renseigne VOLUME_ID dans .env}"

echo ">> Création du pod '${POD_NAME}' (${GPU_ID})"
OUT=$(runpodctl pod create \
  --name "${POD_NAME}" \
  --image "${IMAGE}" \
  --gpu-id "${GPU_ID}" \
  --gpu-count 1 \
  --container-disk-in-gb "${CONTAINER_DISK_GB}" \
  --network-volume-id "${VOLUME_ID}" \
  --volume-mount-path "${VOLUME_MOUNT_PATH}" \
  --ports "8188/http,22/tcp" \
  --env "{\"MODELS_AUTO_DOWNLOAD\":\"${MODELS_AUTO_DOWNLOAD}\",\"DOWNLOAD_FULL_QUALITY\":\"${DOWNLOAD_FULL_QUALITY}\"}" \
  --wait \
  -o json)

echo "$OUT"
NEW_ID=$(echo "$OUT" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

if [[ -z "$NEW_ID" ]]; then
  echo "!! Impossible d'extraire l'ID du pod depuis la sortie ci-dessus. Reporte-le manuellement dans deploy/.env (POD_ID=...)." >&2
  exit 1
fi

save_env_var POD_ID "$NEW_ID"
echo ">> POD_ID=${NEW_ID} enregistré dans deploy/.env"
echo ">> ComfyUI sera accessible via l'onglet 'Connect' du pod sur le port 8188 (HTTP)."
echo ">> Premier démarrage sans modèles sur le volume ? Lance ./07-download-models.sh"
