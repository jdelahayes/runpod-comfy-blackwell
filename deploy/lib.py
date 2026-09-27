"""Utilitaires partagés par les scripts deploy/*.py (équivalent Python de lib.sh).

Contrairement aux versions bash (qui dépendent de `jq`), ces scripts n'ont besoin
d'aucune dépendance externe : `json` (stdlib) remplace `jq`, `urllib` (stdlib)
remplace `curl` pour le polling des URLs.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

DEPLOY_DIR = Path(__file__).resolve().parent
ENV_FILE = DEPLOY_DIR / ".env"


def _parse_env_file(path):
    pairs = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        pairs[key] = value
    return pairs


def load_env():
    if not ENV_FILE.is_file():
        sys.exit(
            f"!! {ENV_FILE} introuvable. Copie deploy/env.example vers deploy/.env "
            f"et complète-le."
        )
    for key, value in _parse_env_file(ENV_FILE).items():
        os.environ[key] = value  # comme `source .env` en bash : le fichier prime


def get_env(key, default=""):
    return os.environ.get(key, default)


def require_env(key, hint=None):
    value = os.environ.get(key, "")
    if not value:
        sys.exit(f"!! {hint or f'{key} manquant dans deploy/.env'}")
    return value


def check_runpodctl():
    if shutil.which("runpodctl") is None:
        sys.exit("!! runpodctl introuvable. Installe-le : https://github.com/runpod/runpodctl")


def setup():
    """À appeler en tout début de chaque script."""
    load_env()
    check_runpodctl()
    require_env("RUNPOD_API_KEY")


def runpodctl(*args):
    """Exécute `runpodctl <args>`, retourne stdout (str). Quitte le script en cas d'échec."""
    cmd = ["runpodctl", *args]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"!! Échec : {' '.join(cmd)}\n{result.stderr}")
    return result.stdout


def runpodctl_json(*args):
    """Comme runpodctl(), mais ajoute `-o json` et parse la sortie."""
    return json.loads(runpodctl(*args, "-o", "json"))


def save_env_var(key, value):
    """Ajoute ou met à jour KEY=value dans deploy/.env, en conservant le reste du fichier."""
    lines = ENV_FILE.read_text().splitlines()
    for i, line in enumerate(lines):
        if line.startswith(f"{key}="):
            lines[i] = f"{key}={value}"
            break
    else:
        lines.append(f"{key}={value}")
    ENV_FILE.write_text("\n".join(lines) + "\n")


def redact(payload_dict, obj):
    """Sérialise `obj` en JSON en masquant les valeurs de payload_dict qui ressemblent à des
    secrets (tokens), pour ne pas les laisser traîner dans le terminal/l'historique."""
    text = json.dumps(obj, ensure_ascii=False)
    for key, value in payload_dict.items():
        if value:
            text = text.replace(value, f"***{key}***")
    return text
