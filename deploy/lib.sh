#!/usr/bin/env bash
# Chargé par les scripts deploy/*.sh. Vérifie l'environnement et centralise la conf runpodctl.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DEPLOY_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "!! ${ENV_FILE} introuvable. Copie deploy/env.example vers deploy/.env et complète-le." >&2
  exit 1
fi

command -v runpodctl >/dev/null 2>&1 || {
  echo "!! runpodctl introuvable. Installe-le : https://github.com/runpod/runpodctl" >&2
  exit 1
}

: "${RUNPOD_API_KEY:?RUNPOD_API_KEY manquant dans deploy/.env}"
# RUNPOD_API_KEY est déjà exportée (via `set -a` ci-dessus) : runpodctl la lit directement
# depuis l'environnement. `runpodctl config --apiKey` est déprécié (persiste en clair dans
# ~/.runpod/config.toml en plus, ce qu'on évite ici).
export RUNPOD_API_KEY

# Persiste une clé=valeur dans deploy/.env (utilisé pour écrire VOLUME_ID / POD_ID après création).
save_env_var() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}
