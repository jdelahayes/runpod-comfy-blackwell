#!/usr/bin/env bash
# Crée les secrets RunPod référencés par le template et le pod ({{ RUNPOD_SECRET_<nom> }}) à partir
# des tokens de deploy/.env : HF_TOKEN -> hf_token, CIVITAI_TOKEN -> civitai_token,
# JUPYTER_TOKEN -> jupyter_token. Un secret déjà présent est conservé, sauf avec --force qui le
# remplace par la valeur de .env (l'API ne permet ni de relire ni de modifier la valeur d'un
# secret : --force le supprime puis le recrée, en gardant sa description).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || {
  echo "!! jq est requis par ce script (appels GraphQL RunPod). Installe-le (apt install jq / brew install jq)." >&2
  exit 1
}

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

EXISTING=$(runpod_graphql '{ myself { secrets { id name description } } }' | jq -c '.myself.secrets // []')

for pair in HF_TOKEN:hf_token CIVITAI_TOKEN:civitai_token JUPYTER_TOKEN:jupyter_token; do
  var="${pair%%:*}" name="${pair##*:}"
  value="${!var:-}"
  secret=$(echo "$EXISTING" | jq -c --arg n "$name" '[.[] | select(.name == $n)][0] // empty')

  if [[ -z "$value" ]]; then
    if [[ -n "$secret" ]]; then
      echo ">> [${name}] ${var} vide dans .env, secret existant conservé"
    else
      echo "!! [${name}] ${var} vide dans .env et secret absent : {{ RUNPOD_SECRET_${name} }} ne sera pas résolu dans le pod" >&2
    fi
    continue
  fi

  description=""
  if [[ -n "$secret" ]]; then
    if [[ "$FORCE" -eq 0 ]]; then
      echo ">> [${name}] existe déjà, conservé (relance avec --force pour le remplacer par ${var})"
      continue
    fi
    description=$(echo "$secret" | jq -r '.description // empty')
    runpod_graphql 'mutation($id: ID!) { secretDelete(id: $id) }' \
      "$(jq -n --arg id "$(echo "$secret" | jq -r '.id')" '{id: $id}')" >/dev/null
    action="remplacé"
  else
    action="créé"
  fi

  runpod_graphql 'mutation($input: SecretCreateInput!) { secretCreate(input: $input) { id } }' \
    "$(jq -n --arg n "$name" --arg v "$value" --arg d "$description" \
      '{input: ({name: $n, value: $v} + (if $d == "" then {} else {description: $d} end))}')" >/dev/null
  echo ">> [${name}] ${action} depuis ${var}"
done
