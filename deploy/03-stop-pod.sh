#!/usr/bin/env bash
# Stoppe le pod (facturation GPU arrêtée, le Network Volume et le disque conteneur restent).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
: "${POD_ID:?Aucun POD_ID dans .env}"
runpodctl pod stop "$POD_ID"
