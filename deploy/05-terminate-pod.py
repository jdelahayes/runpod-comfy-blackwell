#!/usr/bin/env python3
"""Supprime définitivement le pod (le disque conteneur est perdu ; le Network Volume survit)."""
import lib


def main():
    lib.setup()
    pod_id = lib.require_env("POD_ID", "Aucun POD_ID dans .env")
    pod_name = lib.get_env("POD_NAME", "")

    confirm = input(f"Supprimer définitivement le pod {pod_id} ({pod_name}) ? [y/N] ")
    if confirm.strip().lower() != "y":
        print("Annulé.")
        return

    lib.runpodctl("pod", "delete", pod_id)
    lib.save_env_var("POD_ID", "")
    print(f">> Pod supprimé. Le Network Volume ({lib.get_env('VOLUME_ID')}) est conservé.")


if __name__ == "__main__":
    main()
