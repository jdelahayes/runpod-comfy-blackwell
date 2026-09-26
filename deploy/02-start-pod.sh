#!/usr/bin/env bash
# Crée le pod ComfyUI/MiniMax H3 sur une RTX PRO 6000, avec le Network Volume monté.
# Une fois le pod créé, attend que les ports HTTP exposés répondent vraiment (pas juste que
# SSH soit joignable) avant d'afficher leurs URLs publiques.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${VOLUME_ID:?Lance 01-create-volume.sh avant celui-ci, ou renseigne VOLUME_ID dans .env}"

PORTS="8188/http,22/tcp"
URL_WAIT_TIMEOUT="${URL_WAIT_TIMEOUT:-900}" # 15 min : large marge si MODELS_AUTO_DOWNLOAD=1

echo ">> Création du pod '${POD_NAME}' (${GPU_ID})"
OUT=$(runpodctl pod create \
  --name "${POD_NAME}" \
  --image "${IMAGE}" \
  --gpu-id "${GPU_ID}" \
  --gpu-count 1 \
  --container-disk-in-gb "${CONTAINER_DISK_GB}" \
  --network-volume-id "${VOLUME_ID}" \
  --volume-mount-path "${VOLUME_MOUNT_PATH}" \
  --ports "${PORTS}" \
  --env "{\"MODELS_AUTO_DOWNLOAD\":\"${MODELS_AUTO_DOWNLOAD}\",\"DOWNLOAD_FULL_QUALITY\":\"${DOWNLOAD_FULL_QUALITY}\",\"HF_TOKEN\":\"${HF_TOKEN:-}\",\"CIVITAI_TOKEN\":\"${CIVITAI_TOKEN:-}\"}" \
  --wait \
  -o json)

# La réponse de l'API peut réverbérer les env passées ci-dessus : on masque les tokens
# avant affichage pour ne pas les laisser traîner dans le terminal/l'historique.
REDACTED_OUT="$OUT"
[[ -n "${HF_TOKEN:-}" ]] && REDACTED_OUT="${REDACTED_OUT//${HF_TOKEN}/***HF_TOKEN***}"
[[ -n "${CIVITAI_TOKEN:-}" ]] && REDACTED_OUT="${REDACTED_OUT//${CIVITAI_TOKEN}/***CIVITAI_TOKEN***}"
echo "$REDACTED_OUT"
NEW_ID=$(echo "$OUT" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

if [[ -z "$NEW_ID" ]]; then
  echo "!! Impossible d'extraire l'ID du pod depuis la sortie ci-dessus. Reporte-le manuellement dans deploy/.env (POD_ID=...)." >&2
  exit 1
fi

save_env_var POD_ID "$NEW_ID"
echo ">> POD_ID=${NEW_ID} enregistré dans deploy/.env"

# Extrait les ports ".../http" de PORTS et construit leur URL proxy RunPod
# (https://<pod-id>-<port>.proxy.runpod.net). --wait n'attend que SSH, pas ces ports : on
# poll donc chaque URL jusqu'à ce qu'elle réponde vraiment avant de la donner comme prête.
HTTP_PORTS=()
IFS=',' read -ra PORT_ENTRIES <<< "$PORTS"
for entry in "${PORT_ENTRIES[@]}"; do
  [[ "$entry" == */http ]] && HTTP_PORTS+=("${entry%/http}")
done

if [[ "${#HTTP_PORTS[@]}" -eq 0 ]]; then
  echo ">> Aucun port HTTP exposé, rien à attendre."
  exit 0
fi

if [[ "${MODELS_AUTO_DOWNLOAD}" == "1" ]]; then
  echo ">> MODELS_AUTO_DOWNLOAD=1 : le pod télécharge les modèles avant de démarrer ComfyUI,"
  echo "   ça peut prendre plusieurs minutes (~42 Go pour le kit turbo) avant que l'URL réponde."
fi

echo ">> Attente que les URLs répondent (timeout ${URL_WAIT_TIMEOUT}s) :"
declare -A READY
elapsed=0
while [[ "$elapsed" -lt "$URL_WAIT_TIMEOUT" ]]; do
  all_ready=1
  for port in "${HTTP_PORTS[@]}"; do
    [[ -n "${READY[$port]:-}" ]] && continue
    url="https://${NEW_ID}-${port}.proxy.runpod.net"
    code=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "$url" || true)
    if [[ "$code" == "200" ]]; then
      READY[$port]=1
      echo ">> [${port}] prêt : ${url}"
    else
      all_ready=0
    fi
  done
  [[ "$all_ready" -eq 1 ]] && break
  sleep 10
  elapsed=$((elapsed + 10))
done

for port in "${HTTP_PORTS[@]}"; do
  if [[ -z "${READY[$port]:-}" ]]; then
    echo "!! [${port}] ne répond toujours pas après ${URL_WAIT_TIMEOUT}s : https://${NEW_ID}-${port}.proxy.runpod.net" >&2
    echo "   Vérifie les logs du pod (./06-ssh.sh) — peut-être encore en train de démarrer/télécharger." >&2
  fi
done

echo ">> Premier démarrage sans modèles sur le volume ? Lance ./07-download-models.sh"
