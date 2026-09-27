#!/usr/bin/env python3
"""Crée les secrets RunPod référencés par le template et le pod ({{ RUNPOD_SECRET_<nom> }}) à partir
des tokens de deploy/.env : HF_TOKEN -> hf_token, CIVITAI_TOKEN -> civitai_token,
JUPYTER_TOKEN -> jupyter_token. Un secret déjà présent est conservé, sauf avec --force qui le
remplace par la valeur de .env (l'API ne permet ni de relire ni de modifier la valeur d'un
secret : --force le supprime puis le recrée, en gardant sa description).
"""
import sys

import lib

SECRETS = {
    "HF_TOKEN": "hf_token",
    "CIVITAI_TOKEN": "civitai_token",
    "JUPYTER_TOKEN": "jupyter_token",
}


def main():
    lib.setup()
    force = "--force" in sys.argv[1:]

    data = lib.runpod_graphql("{ myself { secrets { id name description } } }")
    existing = {s["name"]: s for s in data["myself"]["secrets"] or []}

    for var, name in SECRETS.items():
        value = lib.get_env(var)
        secret = existing.get(name)

        if not value:
            if secret:
                print(f">> [{name}] {var} vide dans .env, secret existant conservé")
            else:
                print(
                    f"!! [{name}] {var} vide dans .env et secret absent : "
                    f"{{{{ RUNPOD_SECRET_{name} }}}} ne sera pas résolu dans le pod"
                )
            continue

        secret_input = {"name": name, "value": value}
        if secret:
            if not force:
                print(f">> [{name}] existe déjà, conservé (relance avec --force pour le remplacer par {var})")
                continue
            if secret.get("description"):
                secret_input["description"] = secret["description"]
            lib.runpod_graphql("mutation($id: ID!) { secretDelete(id: $id) }", {"id": secret["id"]})
            action = "remplacé"
        else:
            action = "créé"

        lib.runpod_graphql(
            "mutation($input: SecretCreateInput!) { secretCreate(input: $input) { id } }",
            {"input": secret_input},
        )
        print(f">> [{name}] {action} depuis {var}")


if __name__ == "__main__":
    main()
