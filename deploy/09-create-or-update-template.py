#!/usr/bin/env python3
"""Crée le template RunPod s'il n'existe pas encore (recherché par nom parmi tes templates),
ou le met à jour sinon. Un template RunPod regroupe image + ports + env + disque, réutilisable
depuis le dashboard RunPod ou via `runpodctl pod create --template-id <id>`.
"""
import json

import lib

PORTS = "8188/http,8888/http,22/tcp"
PORT_LABELS = "8188=ComfyUI,8888=Jupyter Lab,22=SSH"


def build_env_payload():
    # Les tokens ne sont jamais écrits en clair dans le template : on référence des secrets
    # RunPod (Settings -> Secrets, à créer une fois sous les noms hf_token, civitai_token,
    # jupyter_token), que RunPod substitue au démarrage du pod.
    return {
        "MODELS_AUTO_DOWNLOAD": lib.get_env("MODELS_AUTO_DOWNLOAD", "0"),
        "MODEL_TAGS": lib.get_env("MODEL_TAGS", "turbo"),
        "HF_TOKEN": "{{ RUNPOD_SECRET_hf_token }}",
        "CIVITAI_TOKEN": "{{ RUNPOD_SECRET_civitai_token }}",
        "JUPYTER_TOKEN": "{{ RUNPOD_SECRET_jupyter_token }}",
    }


def find_template_id(name):
    templates = lib.runpodctl_json("template", "list", "--type", "user", "--limit", "100")
    for t in templates:
        if t.get("name") == name:
            return t["id"]
    return None


def main():
    lib.setup()
    template_name = lib.require_env("TEMPLATE_NAME")
    env_payload = build_env_payload()
    env_json = json.dumps(env_payload)

    # On repart de TEMPLATE_ID si déjà connu (évite une recherche par nom, plus rapide et sans
    # ambiguïté en cas d'homonymes) ; sinon on cherche parmi les templates existants.
    template_id = lib.get_env("TEMPLATE_ID")
    if not template_id:
        print(f">> Recherche d'un template existant nommé '{template_name}'...")
        template_id = find_template_id(template_name)

    if template_id:
        print(f">> Mise à jour du template existant ({template_id})")
        out = lib.runpodctl_json(
            "template", "update", template_id,
            "--image", lib.require_env("IMAGE"),
            "--container-disk-in-gb", lib.require_env("CONTAINER_DISK_GB"),
            "--ports", PORTS,
            "--port-labels", PORT_LABELS,
            "--env", env_json,
        )
    else:
        print(f">> Aucun template '{template_name}' trouvé, création")
        out = lib.runpodctl_json(
            "template", "create",
            "--name", template_name,
            "--image", lib.require_env("IMAGE"),
            "--container-disk-in-gb", lib.require_env("CONTAINER_DISK_GB"),
            "--volume-in-gb", lib.require_env("VOLUME_SIZE_GB"),
            "--volume-mount-path", lib.require_env("VOLUME_MOUNT_PATH"),
            "--ports", PORTS,
            "--port-labels", PORT_LABELS,
            "--env", env_json,
        )

    print(json.dumps(out, ensure_ascii=False))

    new_id = out.get("id")
    if not new_id:
        raise SystemExit(
            "!! Impossible d'extraire l'ID du template depuis la sortie ci-dessus. "
            "Reporte-le manuellement dans deploy/.env (TEMPLATE_ID=...)."
        )

    lib.save_env_var("TEMPLATE_ID", new_id)
    lib.save_env_var("TEMPLATE_NAME", template_name)
    print(f">> TEMPLATE_ID={new_id} enregistré dans deploy/.env")
    gpu_id = lib.get_env("GPU_ID", "")
    print(
        f'>> Utilisable via : runpodctl pod create --template-id {new_id} '
        f'--gpu-id "{gpu_id}" --network-volume-id "$VOLUME_ID"'
    )


if __name__ == "__main__":
    main()
