#!/usr/bin/env python3
"""Crée le Network Volume qui stockera les modèles MiniMax H3 (persiste entre les pods).
À lancer une seule fois. Le VOLUME_ID est écrit dans deploy/.env.
"""
import lib


def main():
    lib.setup()

    if lib.get_env("VOLUME_ID"):
        print(f">> VOLUME_ID déjà défini ({lib.get_env('VOLUME_ID')}) dans .env, rien à faire.")
        return

    name = f"{lib.require_env('POD_NAME')}-models"
    size = lib.require_env("VOLUME_SIZE_GB")
    dc = lib.require_env("DATA_CENTER_ID")

    print(f">> Création du volume '{name}' ({size} Go, {dc})")
    out = lib.runpodctl_json(
        "network-volume", "create",
        "--name", name,
        "--size", size,
        "--data-center-id", dc,
    )
    print(out)

    new_id = out.get("id")
    if not new_id:
        raise SystemExit(
            "!! Impossible d'extraire l'ID du volume depuis la sortie ci-dessus. "
            "Reporte-le manuellement dans deploy/.env (VOLUME_ID=...)."
        )

    lib.save_env_var("VOLUME_ID", new_id)
    print(f">> VOLUME_ID={new_id} enregistré dans deploy/.env")
    print(f">> Important : ton pod devra être créé dans le MÊME data-center ({dc}) que ce volume.")


if __name__ == "__main__":
    main()
