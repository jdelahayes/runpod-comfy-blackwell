#!/usr/bin/env python3
"""Peuple le Network Volume avec des modèles, via le script embarqué dans l'image
(/opt/scripts/download_models.py, config JSON + tags/id — voir scripts/models.json).
Se connecte en SSH et lui transmet tous les arguments reçus ici.

Usage:
  ./07-download-models.py                        # tag MODEL_TAGS de .env (défaut: turbo)
  ./07-download-models.py --tag hq                # un tag précis
  ./07-download-models.py --id lora-fl2v-8step     # un seul modèle par id
  ./07-download-models.py --list                  # explorer les modèles/tags disponibles
"""
import shlex
import subprocess
import sys

import lib


def main():
    lib.setup()
    pod_id = lib.require_env("POD_ID", "Aucun POD_ID dans .env")
    volume_mount = lib.require_env("VOLUME_MOUNT_PATH")

    # `runpodctl ssh connect` est déprécié ; `ssh info` le remplace mais ne se connecte pas
    # elle-même (juste les infos), donc on exécute nous-mêmes la commande ssh retournée.
    info = lib.runpodctl_json("ssh", "info", pod_id)
    ssh_cmd = info.get("ssh_command", "")
    if not ssh_cmd:
        print("!! Impossible de récupérer la commande SSH automatiquement (runpodctl ssh info).", file=sys.stderr)
        print("   Lance ./06-ssh.py, connecte-toi, puis exécute manuellement :", file=sys.stderr)
        print(f"   /opt/scripts/download_models.py {volume_mount}/models --tag {lib.get_env('MODEL_TAGS', 'turbo')}", file=sys.stderr)
        sys.exit(1)

    # Sans argument : utilise MODEL_TAGS de .env (défaut "turbo" dans download_models.py
    # lui-même si même cette variable est absente).
    extra_args = sys.argv[1:] or ["--tag", lib.get_env("MODEL_TAGS", "turbo")]

    # Les tokens ne transitent jamais en clair depuis .env : le pod les reçoit des secrets
    # RunPod et entrypoint.sh les persiste dans /etc/environment. On charge ce fichier
    # explicitement, car une session SSH n'hérite pas forcément des env du conteneur selon la
    # config PAM/sshd.
    remote_cmd = (
        "set -a; . /etc/environment; set +a; "
        f"/opt/scripts/download_models.py {shlex.quote(volume_mount + '/models')} "
        + " ".join(shlex.quote(a) for a in extra_args)
    )

    print(f">> Connexion : {ssh_cmd}")
    subprocess.run([*shlex.split(ssh_cmd), remote_cmd], check=True)


if __name__ == "__main__":
    main()
