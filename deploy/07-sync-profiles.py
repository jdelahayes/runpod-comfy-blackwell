#!/usr/bin/env python3
"""Pilote les profils d'utilisation sur le pod (/opt/scripts/comfy_profiles.py, voir
scripts/profiles.json et la section Profils du README) : se connecte en SSH et lui transmet
les arguments reçus ici. Le pod synchronise déjà COMFY_PROFILES à chaque démarrage ; ce script
sert à ajouter un profil sans redémarrer, ou à explorer les profils disponibles.

Usage:
  ./07-sync-profiles.py                        # sync des profils COMFY_PROFILES de .env
  ./07-sync-profiles.py sync krea2,flux2-klein  # sync de profils précis
  ./07-sync-profiles.py sync krea2 --dry-run    # ce qui serait installé, sans rien faire
  ./07-sync-profiles.py list                    # profils disponibles
  ./07-sync-profiles.py show minimax-h3-all     # contenu d'un profil et ce qui est déjà là
"""
import shlex
import subprocess
import sys

import lib


def main():
    lib.setup()
    pod_id = lib.require_env("POD_ID", "Aucun POD_ID dans .env")

    args = sys.argv[1:]
    if not args:
        profiles = lib.require_env(
            "COMFY_PROFILES",
            "COMFY_PROFILES vide dans .env : indique les profils, ex. ./07-sync-profiles.py sync minimax-h3-all",
        )
        args = ["sync", profiles]

    # `runpodctl ssh connect` est déprécié ; `ssh info` le remplace mais ne se connecte pas
    # elle-même (juste les infos), donc on exécute nous-mêmes la commande ssh retournée.
    info = lib.runpodctl_json("ssh", "info", pod_id)
    ssh_cmd = info.get("ssh_command", "")
    if not ssh_cmd:
        print("!! Impossible de récupérer la commande SSH automatiquement (runpodctl ssh info).", file=sys.stderr)
        print("   Lance ./06-ssh.py, connecte-toi, puis exécute manuellement :", file=sys.stderr)
        print(f"   /opt/scripts/comfy_profiles.py {' '.join(args)}", file=sys.stderr)
        sys.exit(1)

    # Les tokens et la config des profils (COMFY_PROFILES_CONFIG, MODELS_VOLUME_DIR, ...) ne
    # transitent jamais depuis .env : le pod les reçoit à sa création et entrypoint.sh les
    # persiste dans /etc/environment. On charge ce fichier explicitement, car une session SSH
    # n'hérite pas forcément des env du conteneur selon la config PAM/sshd.
    remote_cmd = (
        "set -a; . /etc/environment; set +a; /opt/scripts/comfy_profiles.py "
        + " ".join(shlex.quote(a) for a in args)
    )

    print(f">> Connexion : {ssh_cmd}")
    subprocess.run([*shlex.split(ssh_cmd), remote_cmd], check=True)

    if args[0] == "sync":
        print(">> Nouveaux modèles : visibles dans ComfyUI après un rafraîchissement de la page (touche R).")
        print(f"   Nouveaux custom nodes : nécessitent de redémarrer ComfyUI (runpodctl pod restart {pod_id}).")


if __name__ == "__main__":
    main()
