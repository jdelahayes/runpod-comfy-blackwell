#!/usr/bin/env python3
"""Telecharge les modeles MiniMax H3 listes dans un fichier de config JSON, filtres par
tag et/ou par id.

Usage:
  download_models.py [DEST_DIR] [--config FICHIER] [--tag t1,t2] [--id id1,id2] [--list]

Sans --tag ni --id : tag "turbo" par defaut.
Sans --config : /opt/scripts/models.json (fichier embarque dans l'image).
DEST_DIR : dossier cible (defaut: $MODELS_VOLUME_DIR ou /runpod-volume/models).

Exemples:
  download_models.py --list                     # explorer les modeles/tags disponibles
  download_models.py --tag turbo                 # kit turbo complet (comportement par defaut)
  download_models.py --tag hq                    # base seule, sans LoRA (rendu qualite max)
  download_models.py --id lora-fl2v-8step         # un seul fichier, par son id
  download_models.py --tag turbo,compact          # cumule plusieurs tags
"""
import argparse
import json
import os
import subprocess
import sys

DEFAULT_CONFIG = "/opt/scripts/models.json"
DEFAULT_DEST = os.environ.get("MODELS_VOLUME_DIR", "/runpod-volume/models")


def load_models(config_path):
    if not os.path.isfile(config_path):
        sys.exit(f"!! Fichier de config introuvable : {config_path}")
    with open(config_path) as f:
        data = json.load(f)
    return data["models"]


def select_models(models, tags, ids):
    tags = set(tags)
    ids = set(ids)
    selected, seen = [], set()
    for m in models:
        if (ids and m["id"] in ids) or (tags and tags & set(m.get("tags", []))):
            if m["id"] not in seen:
                selected.append(m)
                seen.add(m["id"])
    return selected


def print_list(models):
    all_tags = sorted({t for m in models for t in m.get("tags", [])})
    print(f"Tags disponibles : {', '.join(all_tags)}\n")
    for m in models:
        print(f"- {m['id']:<28} tags=[{','.join(m.get('tags', []))}]")
        if m.get("description"):
            print(f"    {m['description']}")


def download(model, dest_dir):
    subdir = model.get("local_subdir", "")
    local_dir = os.path.join(dest_dir, subdir) if subdir else dest_dir
    os.makedirs(local_dir, exist_ok=True)
    print(f">> [{model['id']}] hf download {model['repo']} "
          f"({len(model['files'])} fichier(s)) -> {local_dir}")
    subprocess.run(
        ["hf", "download", model["repo"], *model["files"], "--local-dir", local_dir],
        check=True,
    )


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("dest_dir", nargs="?", default=DEFAULT_DEST)
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--tag", default="", help="tags separes par des virgules")
    parser.add_argument("--id", dest="ids", default="", help="ids separes par des virgules")
    parser.add_argument("--list", action="store_true", help="liste les modeles/tags et quitte")
    args = parser.parse_args()

    models = load_models(args.config)

    if args.list:
        print_list(models)
        return

    tags = [t.strip() for t in args.tag.split(",") if t.strip()]
    ids = [i.strip() for i in args.ids.split(",") if i.strip()]
    if not tags and not ids:
        tags = ["turbo"]
        print(">> Aucun --tag/--id fourni, tag par defaut : turbo")

    selected = select_models(models, tags, ids)
    if not selected:
        sys.exit(
            f"!! Aucun modele ne correspond a tag={tags or '-'} id={ids or '-'}. "
            f"Utilise --list pour voir les options disponibles."
        )

    print(f">> Cible : {args.dest_dir}")
    print(f">> {len(selected)} modele(s) selectionne(s) : "
          f"{', '.join(m['id'] for m in selected)}")
    if os.environ.get("HF_TOKEN"):
        print(">> HF_TOKEN detecte, authentification Hugging Face activee.")
    else:
        print(">> Pas de HF_TOKEN : telechargement anonyme (suffisant pour ces depots publics).")

    for model in selected:
        download(model, args.dest_dir)

    print(f">> Termine. Contenu de {args.dest_dir} :")
    subprocess.run(f"du -sh {args.dest_dir}/*/ 2>/dev/null", shell=True, check=False)


if __name__ == "__main__":
    main()
