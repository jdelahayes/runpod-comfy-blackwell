#!/usr/bin/env python3
"""Crée le pod ComfyUI/MiniMax H3 sur une RTX PRO 6000, avec le Network Volume monté.
Une fois le pod créé, attend que les ports HTTP exposés répondent vraiment (pas juste que
SSH soit joignable) avant d'afficher leurs URLs publiques.
"""
import json
import time
import urllib.error
import urllib.request

import lib

PORTS = "8188/http,8888/http,22/tcp"


def check_url(url, timeout=5):
    """Retourne le code HTTP final (suit les redirections, comme `curl -L`), ou None si
    injoignable (connexion refusée, timeout, ...)."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return None


def build_env_payload():
    # Les tokens ne sont jamais passés en clair au pod : on référence des secrets RunPod (créés
    # depuis .env par 10-create-or-update-secrets.py), que RunPod substitue au démarrage du pod.
    return {
        "MODELS_AUTO_DOWNLOAD": lib.get_env("MODELS_AUTO_DOWNLOAD", "0"),
        "MODEL_TAGS": lib.get_env("MODEL_TAGS", "turbo"),
        "HF_TOKEN": "{{ RUNPOD_SECRET_hf_token }}",
        "CIVITAI_TOKEN": "{{ RUNPOD_SECRET_civitai_token }}",
        "JUPYTER_TOKEN": "{{ RUNPOD_SECRET_jupyter_token }}",
    }


def main():
    lib.setup()
    volume_id = lib.require_env(
        "VOLUME_ID", "Lance 01-create-volume.py avant celui-ci, ou renseigne VOLUME_ID dans .env"
    )
    url_wait_timeout = int(lib.get_env("URL_WAIT_TIMEOUT", "900"))  # 15 min par défaut

    pod_name = lib.require_env("POD_NAME")
    gpu_id = lib.require_env("GPU_ID")
    env_payload = build_env_payload()

    print(f">> Création du pod '{pod_name}' ({gpu_id})")
    out = lib.runpodctl_json(
        "pod", "create",
        "--name", pod_name,
        "--image", lib.require_env("IMAGE"),
        "--gpu-id", gpu_id,
        "--gpu-count", "1",
        "--container-disk-in-gb", lib.require_env("CONTAINER_DISK_GB"),
        "--network-volume-id", volume_id,
        "--volume-mount-path", lib.require_env("VOLUME_MOUNT_PATH"),
        "--ports", PORTS,
        "--env", json.dumps(env_payload),
        "--wait",
    )

    print(json.dumps(out, ensure_ascii=False))

    new_id = out.get("id")
    if not new_id:
        raise SystemExit(
            "!! Impossible d'extraire l'ID du pod depuis la sortie ci-dessus. "
            "Reporte-le manuellement dans deploy/.env (POD_ID=...)."
        )
    lib.save_env_var("POD_ID", new_id)
    print(f">> POD_ID={new_id} enregistré dans deploy/.env")

    # --wait n'attend que SSH, pas ces ports HTTP : on poll donc chaque URL proxy RunPod
    # (https://<pod-id>-<port>.proxy.runpod.net) jusqu'à ce qu'elle réponde vraiment.
    http_ports = [p.split("/")[0] for p in PORTS.split(",") if p.endswith("/http")]
    if not http_ports:
        print(">> Aucun port HTTP exposé, rien à attendre.")
        return

    if env_payload["MODELS_AUTO_DOWNLOAD"] == "1":
        print(f">> MODELS_AUTO_DOWNLOAD=1 : le pod télécharge les modèles (tag: {env_payload['MODEL_TAGS']}) avant")
        print("   de démarrer ComfyUI, ça peut prendre plusieurs minutes avant que l'URL réponde.")

    print(f">> Attente que les URLs répondent (timeout {url_wait_timeout}s) :")
    ready = set()
    elapsed = 0
    while elapsed < url_wait_timeout and len(ready) < len(http_ports):
        for port in http_ports:
            if port in ready:
                continue
            url = f"https://{new_id}-{port}.proxy.runpod.net"
            if check_url(url) == 200:
                ready.add(port)
                print(f">> [{port}] prêt : {url}")
        if len(ready) < len(http_ports):
            time.sleep(10)
            elapsed += 10

    for port in http_ports:
        if port not in ready:
            print(
                f"!! [{port}] ne répond toujours pas après {url_wait_timeout}s : "
                f"https://{new_id}-{port}.proxy.runpod.net"
            )
            print("   Vérifie les logs du pod (./06-ssh.py) — peut-être encore en train de démarrer/télécharger.")

    print(">> Token JupyterLab : valeur du secret RunPod 'jupyter_token' (voir 10-create-or-update-secrets.py).")

    print(">> Premier démarrage sans modèles sur le volume ? Lance ./07-download-models.py")


if __name__ == "__main__":
    main()
