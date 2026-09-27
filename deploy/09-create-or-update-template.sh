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
PORT_LABELS="8188=ComfyUI,8888=Jupyter Lab,22=SSH"
# Les tokens ne sont jamais écrits en clair dans le template : on référence des secrets RunPod
# (Settings -> Secrets, à créer une fois sous les noms hf_token, civitai_token, jupyter_token),
# que RunPod substitue au démarrage du pod.
ENV_JSON="{\"MODELS_AUTO_DOWNLOAD\":\"${MODELS_AUTO_DOWNLOAD}\",\"MODEL_TAGS\":\"${MODEL_TAGS:-turbo}\",\"HF_TOKEN\":\"{{ RUNPOD_SECRET_hf_token }}\",\"CIVITAI_TOKEN\":\"{{ RUNPOD_SECRET_civitai_token }}\",\"JUPYTER_TOKEN\":\"{{ RUNPOD_SECRET_jupyter_token }}\"}"

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
    --port-labels "${PORT_LABELS}" \
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
    --port-labels "${PORT_LABELS}" \
    --env "${ENV_JSON}" \
    -o json)
fi

echo "$OUT"

NEW_ID=$(echo "$OUT" | jq -r '.id // empty')
if [[ -z "$NEW_ID" ]]; then
  echo "!! Impossible d'extraire l'ID du template depuis la sortie ci-dessus. Reporte-le manuellement dans deploy/.env (TEMPLATE_ID=...)." >&2
  exit 1
fi

save_env_var TEMPLATE_ID "$NEW_ID"
save_env_var TEMPLATE_NAME "${TEMPLATE_NAME}"
echo ">> TEMPLATE_ID=${NEW_ID} enregistré dans deploy/.env"
echo ">> Utilisable via : runpodctl pod create --template-id ${NEW_ID} --gpu-id \"${GPU_ID}\" --network-volume-id \"\${VOLUME_ID}\""
