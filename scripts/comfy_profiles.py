#!/usr/bin/env python3
"""Profils d'utilisation ComfyUI (minimax-h3-all, flux2-klein, ...) : chaque profil décrit les
modèles, custom nodes, workflows et paquets pip dont il a besoin. `sync` installe ce qui
manque et ne touche jamais à ce qui est déjà présent — relançable à volonté (c'est ce que fait
entrypoint.sh à chaque démarrage du pod pour les profils de COMFY_PROFILES).

Usage:
  comfy_profiles.py [--config FICHIER] list
  comfy_profiles.py [--config FICHIER] show PROFIL[,PROFIL...]
  comfy_profiles.py [--config FICHIER] sync [PROFIL[,PROFIL...]] [--dry-run]

Fichier de config : --config, sinon $COMFY_PROFILES_CONFIG, sinon /opt/scripts/profiles.json
(embarqué dans l'image). S'il pointe vers un fichier absent (ex: sur le Network Volume), la
config de l'image y est d'abord copiée, pour être éditée ensuite.
Profils synchronisés par défaut : $COMFY_PROFILES (séparés par des virgules).

Destinations :
  modèles      -> $MODELS_VOLUME_DIR/<type>/  (ou $COMFY_HOME/models/<type>/ sans volume)
  custom nodes -> <volume>/custom_nodes/<nom>, lié dans $COMFY_HOME/custom_nodes/
                  (ou directement dans $COMFY_HOME/custom_nodes/ sans volume)
  workflows    -> $COMFY_HOME/user/default/workflows/
Les dépendances Python (custom nodes, pip) vivent dans le venv du conteneur : elles sont
réinstallées automatiquement sur un nouveau pod, même si le volume est déjà peuplé.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

DEFAULT_CONFIG = Path("/opt/scripts/profiles.json")
SECTIONS = ("custom_nodes", "pip", "models", "workflows")
# "size" : total calculé par profile_sizes.py (informatif, ignoré par sync).
PROFILE_KEYS = {"description", "size", "extends", *SECTIONS}
SOURCES = ("hf", "url", "civitai")
# Cloudflare (devant civitai.com notamment) rejette le User-Agent par défaut de urllib.
USER_AGENT = "runpod-comfy-profiles"
# Dans le venv, donc propre à ce conteneur : un nouveau pod réinstalle les dépendances.
MARKER_DIR = Path(sys.prefix) / ".comfy-profiles"


class ConfigError(Exception):
    pass


def env_path(name, default):
    return Path(os.environ.get(name) or default)


class Paths:
    def __init__(self):
        self.comfy_home = env_path("COMFY_HOME", "/workspace/ComfyUI")
        models_volume = env_path("MODELS_VOLUME_DIR", "/runpod-volume/models")
        volume_root = models_volume.parent
        has_volume = volume_root.is_dir()
        self.models = models_volume if has_volume else self.comfy_home / "models"
        self.custom_nodes = self.comfy_home / "custom_nodes"
        self.custom_nodes_store = volume_root / "custom_nodes" if has_volume else self.custom_nodes
        self.workflows = self.comfy_home / "user" / "default" / "workflows"
        # Hors des sous-dossiers <type>/ : jamais scanné par ComfyUI ni lié par entrypoint.sh.
        self.staging = self.models / ".staging"


# --- Config -------------------------------------------------------------------------------

def config_path(arg):
    return Path(arg or os.environ.get("COMFY_PROFILES_CONFIG") or DEFAULT_CONFIG)


def is_comment(key):
    return key.startswith("//")


def load_profiles(path):
    if not path.is_file():
        if path != DEFAULT_CONFIG and DEFAULT_CONFIG.is_file():
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(DEFAULT_CONFIG, path)
            print(f">> {path} absent : copie de la config par défaut de l'image ({DEFAULT_CONFIG}).")
        else:
            sys.exit(f"!! Fichier de config introuvable : {path}")
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        sys.exit(f"!! {path} : JSON invalide ({e})")
    profiles = data.get("profiles")
    if not isinstance(profiles, dict) or not profiles:
        sys.exit(f"!! {path} : objet 'profiles' manquant ou vide")
    for name, profile in profiles.items():
        unknown = {k for k in profile if not is_comment(k)} - PROFILE_KEYS
        if unknown:
            sys.exit(
                f"!! Profil '{name}' : clé(s) inconnue(s) {sorted(unknown)} "
                f"(attendues : {', '.join(sorted(PROFILE_KEYS))})"
            )
    return profiles


def split_names(value):
    return [n.strip() for n in (value or "").split(",") if n.strip()]


def resolve(profiles, names):
    """Fusionne les profils demandés et leurs `extends` (parents d'abord, chacun une fois)."""
    merged = {section: [] for section in SECTIONS}
    visited = set()

    def visit(name, stack):
        if name in stack:
            sys.exit(f"!! Cycle dans 'extends' : {' -> '.join([*stack, name])}")
        if name not in profiles:
            sys.exit(f"!! Profil inconnu : '{name}' (disponibles : {', '.join(profiles)})")
        if name in visited:
            return
        visited.add(name)
        profile = profiles[name]
        for parent in profile.get("extends", []):
            visit(parent, [*stack, name])
        for section in SECTIONS:
            for item in profile.get(section, []):
                merged[section].append((name, item))

    for name in names:
        visit(name, [])
    return merged


# --- Téléchargements ----------------------------------------------------------------------

def source_of(item, where):
    found = [k for k in SOURCES if k in item]
    if len(found) != 1:
        raise ConfigError(f"{where} : une (et une seule) source attendue parmi {', '.join(SOURCES)}")
    if found[0] == "hf" and not item.get("file"):
        raise ConfigError(f"{where} : 'file' (chemin dans le dépôt) requis avec 'hf'")
    return found[0]


def target_name(item, where):
    if item.get("name"):
        return item["name"]
    if "hf" in item:
        return Path(item["file"]).name
    raise ConfigError(f"{where} : 'name' (nom du fichier local) requis pour une source url/civitai")


def describe_source(item):
    if "hf" in item:
        rev = f"@{item['revision']}" if item.get("revision") else ""
        return f"hf:{item['hf']}{rev}/{item['file']}"
    if "civitai" in item:
        return f"civitai:{item['civitai']}"
    return item["url"]


def fetch_url(url, dest):
    part = dest.with_name(dest.name + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp, part.open("wb") as out:
            shutil.copyfileobj(resp, out, 16 * 1024 * 1024)
        part.replace(dest)
    finally:
        part.unlink(missing_ok=True)


def fetch(item, dest, paths):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if "hf" in item:
        from huggingface_hub import hf_hub_download  # lit HF_TOKEN tout seul

        paths.staging.mkdir(parents=True, exist_ok=True)
        try:
            downloaded = hf_hub_download(
                repo_id=item["hf"],
                filename=item["file"],
                revision=item.get("revision"),
                local_dir=paths.staging,
            )
            shutil.move(downloaded, dest)
        finally:
            shutil.rmtree(paths.staging, ignore_errors=True)
    elif "civitai" in item:
        url = f"https://civitai.com/api/download/models/{item['civitai']}"
        # Token en paramètre plutôt qu'en en-tête : CivitAI redirige vers un stockage S3 qui
        # refuse un en-tête Authorization en plus de sa propre signature.
        token = os.environ.get("CIVITAI_TOKEN")
        fetch_url(f"{url}?token={token}" if token else url, dest)
    else:
        fetch_url(item["url"], dest)


# --- Dépendances Python -------------------------------------------------------------------

def marker(kind, key, content):
    digest = hashlib.sha256(content.encode()).hexdigest()[:12]
    return MARKER_DIR / f"{kind}-{key}-{digest}"


def pip_install(args):
    if shutil.which("uv"):
        cmd = ["uv", "pip", "install", "--python", sys.executable, *args]
    else:
        cmd = [sys.executable, "-m", "pip", "install", *args]
    subprocess.run(cmd, check=True)


def touch(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch()


# --- Plan ---------------------------------------------------------------------------------

class Step:
    def __init__(self, label, run):
        self.label = label
        self.run = run


def plan_file(item, where, dest_dir, paths):
    source_of(item, where)
    dest = dest_dir / target_name(item, where)
    if dest.exists():
        return dest, None
    return dest, Step(f"{describe_source(item)} -> {dest}", lambda: fetch(item, dest, paths))


def plan_custom_node(item, where, paths):
    url = item.get("git")
    if not url:
        raise ConfigError(f"{where} : 'git' (URL du dépôt) requis")
    name = item.get("name") or url.rstrip("/").removesuffix(".git").rsplit("/", 1)[-1]
    store = paths.custom_nodes_store / name
    link = paths.custom_nodes / name
    steps = []

    if link.exists() and not link.is_symlink() and link != store:
        print(f"   [{name}] déjà présent dans l'image ({link}), version du profil ignorée")
        return name, steps

    if not store.exists():
        ref = item.get("ref")

        def clone():
            if ref:
                # ref peut être un commit : --branch ne l'accepte pas, d'où un clone complet.
                subprocess.run(["git", "clone", url, str(store)], check=True)
                subprocess.run(["git", "-C", str(store), "checkout", ref], check=True)
            else:
                subprocess.run(["git", "clone", "--depth", "1", url, str(store)], check=True)

        steps.append(Step(f"git clone {url}{'@' + ref if ref else ''} -> {store}", clone))

    if link != store and not link.is_symlink():
        steps.append(Step(f"lien {link} -> {store}", lambda: link.symlink_to(store)))

    # Les dépendances ne sont connues qu'une fois le dépôt cloné : on les évalue à l'exécution.
    def deps():
        requirements = store / "requirements.txt"
        if requirements.is_file():
            m = marker("req", name, requirements.read_text())
            if not m.exists():
                print(f">> [{name}] installation de requirements.txt")
                pip_install(["-r", str(requirements)])
                touch(m)
        install_py = store / "install.py"
        if install_py.is_file():
            m = marker("install", name, install_py.read_text())
            if not m.exists():
                print(f">> [{name}] exécution de install.py")
                subprocess.run([sys.executable, "install.py"], cwd=store, check=True)
                touch(m)

    deps_pending = bool(steps) or any(
        f.is_file() and not marker(kind, name, f.read_text()).exists()
        for kind, f in (("req", store / "requirements.txt"), ("install", store / "install.py"))
    )
    if deps_pending:
        steps.append(Step(f"dépendances de {name} (requirements.txt / install.py)", deps))
    return name, steps


def build_plan(merged, paths):
    """Retourne (étapes à exécuter, lignes d'état). Valide toute la config avant d'agir."""
    steps, status, seen = [], [], set()

    for profile, item in merged["custom_nodes"]:
        where = f"[{profile}] custom_nodes"
        name, node_steps = plan_custom_node(item, where, paths)
        if name in seen:
            continue
        seen.add(name)
        steps += node_steps
        status.append(f"custom_node  {name:<40} {'à installer' if node_steps else 'présent'}")

    specs = []
    for profile, spec in merged["pip"]:
        if spec not in specs:
            specs.append(spec)
    missing_specs = [s for s in specs if not marker("pip", "spec", s).exists()]
    for spec in specs:
        status.append(f"pip          {spec:<40} {'à installer' if spec in missing_specs else 'présent'}")
    if missing_specs:
        def install_specs():
            pip_install(missing_specs)
            for s in missing_specs:
                touch(marker("pip", "spec", s))

        steps.append(Step(f"pip install {' '.join(missing_specs)}", install_specs))

    for section in ("models", "workflows"):
        for profile, item in merged[section]:
            where = f"[{profile}] {section}"
            if section == "models":
                if not item.get("type"):
                    raise ConfigError(f"{where} : 'type' (sous-dossier, ex: loras) requis")
                dest_dir = paths.models / item["type"]
            else:
                dest_dir = paths.workflows
            dest, step = plan_file(item, where, dest_dir, paths)
            if dest in seen:
                continue
            seen.add(dest)
            label = f"{item['type']}/{dest.name}" if section == "models" else f"workflow/{dest.name}"
            status.append(f"{section[:-1]:<12} {label:<40} {'à télécharger' if step else 'présent'}")
            if step:
                steps.append(step)

    return steps, status


# --- Commandes ----------------------------------------------------------------------------

def cmd_list(profiles, _args):
    for name, profile in profiles.items():
        extends = profile.get("extends", [])
        counts = ", ".join(f"{len(profile.get(s, []))} {s}" for s in SECTIONS if profile.get(s))
        suffix = f"  (extends: {', '.join(extends)})" if extends else ""
        print(f"- {name}{suffix}")
        if profile.get("size"):
            print(f"    taille : {profile['size']}")
        if profile.get("description"):
            print(f"    {profile['description']}")
        if counts:
            print(f"    propre : {counts}")


def cmd_show(profiles, args):
    names = split_names(args.profiles)
    if not names:
        sys.exit("!! Indique au moins un profil (voir `list`)")
    try:
        _, status = build_plan(resolve(profiles, names), Paths())
    except ConfigError as e:
        sys.exit(f"!! {e}")
    print("\n".join(status) or "(profil vide)")


def cmd_sync(profiles, args):
    names = split_names(args.profiles or os.environ.get("COMFY_PROFILES"))
    if not names:
        print(">> Aucun profil demandé (argument ou COMFY_PROFILES), rien à faire.")
        return 0
    paths = Paths()
    try:
        steps, _ = build_plan(resolve(profiles, names), paths)
    except ConfigError as e:
        sys.exit(f"!! {e}")

    print(f">> Profils : {', '.join(names)} — {len(steps)} action(s) à faire")
    print(f">> Modèles -> {paths.models}")
    if not steps:
        return 0
    if args.dry_run:
        for step in steps:
            print(f"   [dry-run] {step.label}")
        return 0
    print(">> HF_TOKEN détecté." if os.environ.get("HF_TOKEN") else ">> Pas de HF_TOKEN : téléchargements HF anonymes.")

    failures = []
    for i, step in enumerate(steps, 1):
        print(f">> ({i}/{len(steps)}) {step.label}", flush=True)
        try:
            step.run()
        except Exception as e:  # une étape ratée ne doit pas bloquer les suivantes
            print(f"!! Échec : {e}", file=sys.stderr)
            failures.append(step.label)

    if failures:
        print(f"!! {len(failures)} échec(s) sur {len(steps)} :", file=sys.stderr)
        for label in failures:
            print(f"   - {label}", file=sys.stderr)
        return 1
    print(">> Synchronisation terminée.")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--config", help="fichier de profils (défaut : $COMFY_PROFILES_CONFIG ou la config de l'image)")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list", help="liste les profils disponibles")
    show = sub.add_parser("show", help="détaille ce qu'installent des profils, et ce qui est déjà là")
    show.add_argument("profiles")
    sync = sub.add_parser("sync", help="installe ce qui manque pour des profils")
    sync.add_argument("profiles", nargs="?", help="défaut : $COMFY_PROFILES")
    sync.add_argument("--dry-run", action="store_true", help="affiche les actions sans rien faire")
    args = parser.parse_args()

    path = config_path(args.config)
    print(f">> Config : {path}")
    profiles = load_profiles(path)
    commands = {"list": cmd_list, "show": cmd_show, "sync": cmd_sync}
    sys.exit(commands[args.command](profiles, args) or 0)


if __name__ == "__main__":
    main()
