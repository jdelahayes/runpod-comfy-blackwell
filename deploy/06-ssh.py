#!/usr/bin/env python3
"""Ouvre une session SSH interactive sur le pod (nécessite une clé SSH ajoutée à ton compte
RunPod, cf. https://docs.runpod.io/pods/configuration/use-ssh)."""
import os
import shlex
import lib


def main():
    lib.setup()
    pod_id = lib.require_env("POD_ID", "Aucun POD_ID dans .env")

    # `runpodctl ssh connect` est déprécié ; `ssh info` le remplace mais ne se connecte pas
    # elle-même (juste les infos), donc on exécute nous-mêmes la commande ssh retournée.
    info = lib.runpodctl_json("ssh", "info", pod_id)
    ssh_cmd = info.get("ssh_command", "")
    if not ssh_cmd:
        raise SystemExit("!! Impossible de récupérer la commande SSH (runpodctl ssh info).")

    print(f">> {ssh_cmd}")
    argv = shlex.split(ssh_cmd)
    os.execvp(argv[0], argv)


if __name__ == "__main__":
    main()
