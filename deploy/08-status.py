#!/usr/bin/env python3
"""Affiche le statut détaillé du pod."""
import lib


def main():
    lib.setup()
    pod_id = lib.require_env("POD_ID", "Aucun POD_ID dans .env")
    print(lib.runpodctl("pod", "get", pod_id))


if __name__ == "__main__":
    main()
