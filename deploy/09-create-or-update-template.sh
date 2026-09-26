#!/usr/bin/env bash
# Crée le template RunPod s'il n'existe pas encore (recherché par nom parmi tes templates),
# ou le met à jour sinon. Un template RunPod regroupe image + ports + env + disque, réutilisable
# depuis le dashboard RunPod ou via `runpodctl pod create --template-id <id>`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || {
  echo "!! jq est requis par ce script (recherche du template par nom dans la sortie JSON). Installe-le (apt install jq / brew install jq)." >&2
  exit 1
}

: "${TEMPLATE_NAME:?TEMPLATE_NAME manquant dans deploy/.env}"

PORTS="8188/http,8888/http,22/tcp"
ENV_JSON="{\"MODELS_AUTO_DOWNLOAD\":\"${MODELS_AUTO_DOWNLOAD}\",\"DOWNLOAD_FULL_QUALITY\":\"${DOWNLOAD_FULL_QUALITY}\",\"HF_TOKEN\":\"${HF_TOKEN:-}\",\"CIVITAI_TOKEN\":\"${CIVITAI_TOKEN:-}\",\"JUPYTER_TOKEN\":\"${JUPYTER_TOKEN:-}\"}"

# On repart de TEMPLATE_ID si déjà connu (évite une recherche par nom, plus rapide et sans
# ambiguïté en cas d'homonymes) ; sinon on cherche parmi tes templates existants.
if [[ -z "${TEMPLATE_ID:-}" ]]; then
  echo ">> Recherche d'un template existant nommé '${TEMPLATE_NAME}'..."
  EXISTING_ID=$(runpodctl template list --type user --limit 100 -o json \
    | jq -r --arg name "${TEMPLATE_NAME}" '.[]? | select(.name == $name) | .id' | head -1)
  [[ -n "$EXISTING_ID" ]] && TEMPLATE_ID="$EXISTING_ID"
fi

if [[ -n "${TEMPLATE_ID:-}" ]]; then
  echo ">> Mise à jour du template existant (${TEMPLATE_ID})"
  OUT=$(runpodctl template update "${TEMPLATE_ID}" \
    --image "${IMAGE}" \
    --container-disk-in-gb "${CONTAINER_DISK_GB}" \
    --ports "${PORTS}" \
    --env "${ENV_JSON}" \
    -o json)
else
  echo ">> Aucun template '${TEMPLATE_NAME}' trouvé, création"
  OUT=$(runpodctl template create \
    --name "${TEMPLATE_NAME}" \
    --image "${IMAGE}" \
    --container-disk-in-gb "${CONTAINER_DISK_GB}" \
    --volume-in-gb "${VOLUME_SIZE_GB}" \
    --volume-mount-path "${VOLUME_MOUNT_PATH}" \
    --ports "${PORTS}" \
    --env "${ENV_JSON}" \
    -o json)
fi

# Masque les tokens avant affichage (la réponse API peut les réverbérer).
REDACTED_OUT="$OUT"
[[ -n "${HF_TOKEN:-}" ]] && REDACTED_OUT="${REDACTED_OUT//${HF_TOKEN}/***HF_TOKEN***}"
[[ -n "${CIVITAI_TOKEN:-}" ]] && REDACTED_OUT="${REDACTED_OUT//${CIVITAI_TOKEN}/***CIVITAI_TOKEN***}"
[[ -n "${JUPYTER_TOKEN:-}" ]] && REDACTED_OUT="${REDACTED_OUT//${JUPYTER_TOKEN}/***JUPYTER_TOKEN***}"
echo "$REDACTED_OUT"

NEW_ID=$(echo "$OUT" | jq -r '.id // empty')
if [[ -z "$NEW_ID" ]]; then
  echo "!! Impossible d'extraire l'ID du template depuis la sortie ci-dessus. Reporte-le manuellement dans deploy/.env (TEMPLATE_ID=...)." >&2
  exit 1
fi

save_env_var TEMPLATE_ID "$NEW_ID"
save_env_var TEMPLATE_NAME "${TEMPLATE_NAME}"
echo ">> TEMPLATE_ID=${NEW_ID} enregistré dans deploy/.env"
echo ">> Utilisable via : runpodctl pod create --template-id ${NEW_ID} --gpu-id \"${GPU_ID}\" --network-volume-id \"\${VOLUME_ID}\""
