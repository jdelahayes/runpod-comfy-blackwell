#!/usr/bin/env python3
"""Stoppe le pod (facturation GPU arrêtée, le Network Volume et le disque conteneur restent)."""
import lib


def main():
    lib.setup()
    pod_id = lib.require_env("POD_ID", "Aucun POD_ID dans .env")
    print(lib.runpodctl("pod", "stop", pod_id))


if __name__ == "__main__":
    main()
