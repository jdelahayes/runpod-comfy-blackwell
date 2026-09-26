#!/usr/bin/env bash
# Liste les GPU disponibles dans un datacenter RunPod, avec leur stock.
# Usage: ./00-check-gpu-availability.sh [DATA_CENTER_ID] [filtre_regex_nom]
#   ./00-check-gpu-availability.sh                    # DATA_CENTER_ID de .env, tous les GPU
#   ./00-check-gpu-availability.sh US-KS-2            # datacenter explicite, tous les GPU
#   ./00-check-gpu-availability.sh US-KS-2 "6000|5090" # datacenter + filtre par nom (regex, insensible à la casse)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || {
  echo "!! jq est requis par ce script. Installe-le (apt install jq / brew install jq)." >&2
  exit 1
}

DC="${1:-${DATA_CENTER_ID:?Passe un data-center-id en argument, ou renseigne DATA_CENTER_ID dans deploy/.env}}"
FILTER="${2:-.}"

echo ">> GPU dans ${DC}${2:+ (filtre nom: ${2})} :"
runpodctl gpu list --include-unavailable -o json | jq -r --arg dc "$DC" --arg filter "$FILTER" '
  .[] | select(.gpuId | test($filter; "i")) | . as $g |
  ($g.dataCenterAvailability[]? | select(.dataCenterId == $dc)) |
  "\($g.gpuId)\t\(.stockStatus)\t\($g.memoryInGb)GB\t\($g.securePricePerHr // "n/a")$/h secure"
' | column -t -s $'\t'
