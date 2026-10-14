#!/usr/bin/env bash
# Recalcule les tailles de scripts/profiles.json avec profile_sizes.py du dépôt comfyui-profiles,
# cloné à côté de celui-ci (ou dans $COMFYUI_PROFILES_DIR). Tokens HF / CivitAI repris de
# deploy/.env. Arguments transmis tels quels (--force, --dry-run).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node_dir="${COMFYUI_PROFILES_DIR:-${here}/../../comfyui-profiles}"
if [[ ! -f "${node_dir}/profile_sizes.py" ]]; then
  echo "!! ${node_dir}/profile_sizes.py introuvable : clone https://github.com/jdelahayes/comfyui-profiles" >&2
  echo "   à côté de ce dépôt, ou indique son dossier dans COMFYUI_PROFILES_DIR." >&2
  exit 1
fi
env_args=()
[[ -f "${here}/../deploy/.env" ]] && env_args=(--env "${here}/../deploy/.env")
exec python3 "${node_dir}/profile_sizes.py" --config "${here}/profiles.json" "${env_args[@]}" "$@"
