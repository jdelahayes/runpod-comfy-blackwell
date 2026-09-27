#!/usr/bin/env python3
"""Redémarre un pod stoppé (rapide : pas de re-pull d'image ni de re-téléchargement de modèles)."""
import lib


def main():
    lib.setup()
    pod_id = lib.require_env("POD_ID", "Aucun POD_ID dans .env")
    print(lib.runpodctl("pod", "start", pod_id))


if __name__ == "__main__":
    main()
