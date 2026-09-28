# runpod-comfy-blackwell

ComfyUI (dernière stable, v0.37.2) sur [runpod-blackwell-base](../runpod-blackwell-base),
pour RunPod avec une RTX PRO 6000 (Blackwell, 96 Go VRAM). Les modèles et custom nodes de chaque
usage (MiniMax H3, Krea 2, FLUX.2 [klein]...) sont décrits par des **profils** installés au
démarrage du pod (voir [Profils d'utilisation](#profils-dutilisation)).

Aucun poids de modèle dans l'image. Les modèles vivent sur un **Network Volume RunPod**
persistant, montés au démarrage du pod — l'image reste petite (quelques Go) et le pod
démarre vite, à chaque fois. Voir `deploy/` pour tout le cycle de vie via `runpodctl`.

## Architecture

```
runpod-blackwell-base (CUDA 13.0 / PyTorch 2.14 / SageAttention)
        │
        ▼
runpod-comfy-blackwell (ComfyUI v0.37.2 + Manager intégré (--enable-manager) + KJNodes)
        │
        ▼  (au démarrage du pod)
Network Volume RunPod           →  ComfyUI/{models,input,output,user}
  /runpod-volume/{models,input,output,user}   (liens symboliques créés par entrypoint.sh)
```

Tout ce que ComfyUI écrit dans `models/`, `input/`, `output/` et `user/` (workflows enregistrés,
réglages, config du Manager) est donc persisté sur le volume,
y compris les sous-dossiers créés à la volée par des custom nodes (ex. `models/refmods`).

## Profils d'utilisation

Un **profil** décrit tout ce dont un usage a besoin : modèles (diffusion, LoRA, VAE, text
encoders...), custom nodes, workflows et paquets pip. Au démarrage du pod, `entrypoint.sh`
installe ce qui manque pour les profils listés dans `COMFY_PROFILES` (séparés par des virgules)
puis lance ComfyUI. Ce qui est déjà présent n'est jamais retéléchargé : le premier démarrage sur
un volume vide est long, les suivants sont rapides.

Les profils disponibles sont définis dans [`scripts/profiles.json`](scripts/profiles.json) ;
`./07-sync-profiles.py list` les affiche avec leur description.

### Fichier de profils

Par défaut, le pod utilise `scripts/profiles.json`, embarqué dans l'image en
`/opt/scripts/profiles.json`. Pour le personnaliser sans rebuild, fais pointer
`COMFY_PROFILES_CONFIG` vers le Network Volume, par exemple `/runpod-volume/config/profiles.json`.
Si ce fichier n'existe pas encore, la config de l'image y est copiée au premier démarrage : il ne
reste qu'à l'éditer (via JupyterLab par exemple), puis à relancer une synchronisation.

Format :

```jsonc
{
  "profiles": {
    "mon-profil": {
      "description": "Texte libre, affiché par `list`.",
      "extends": ["krea2"],              // hérite de tout le contenu d'autres profils
      "models": [
        // type = sous-dossier de ComfyUI/models (loras, vae, diffusion_models, checkpoints...)
        {"type": "loras", "hf": "org/depot", "file": "chemin/dans/le/depot.safetensors"},
        {"type": "loras", "hf": "org/depot", "file": "x.safetensors", "revision": "main", "name": "renomme.safetensors"},
        {"type": "checkpoints", "civitai": 123456, "name": "mon_modele.safetensors"},   // id de VERSION du modèle
        {"type": "upscale_models", "url": "https://exemple.com/4x.pth", "name": "4x.pth"}
      ],
      "custom_nodes": [
        {"git": "https://github.com/auteur/ComfyUI-Truc.git"},
        {"git": "https://github.com/auteur/ComfyUI-Machin.git", "ref": "v1.2.0", "name": "Machin"}
      ],
      "workflows": [
        {"url": "https://exemple.com/workflow.json", "name": "mon_workflow.json"}
      ],
      "pip": ["onnxruntime-gpu"]
    }
  }
}
```

(Le vrai fichier est du JSON strict, sans commentaires. Les clés qui commencent par `//` sont
ignorées et peuvent servir de commentaires.)

- **Sources** (modèles et workflows) : une seule par élément parmi `hf` (+ `file`, et
  optionnellement `revision`), `civitai` (id de version, utilise `CIVITAI_TOKEN`) ou `url`.
  `name` fixe le nom du fichier local. Il est obligatoire pour `civitai` et `url`, et vaut par
  défaut le nom de `file` pour `hf`.
- **Destinations** : modèles dans `<volume>/models/<type>/`, custom nodes clonés dans
  `<volume>/custom_nodes/` et liés dans `ComfyUI/custom_nodes/`, workflows dans
  `ComfyUI/user/default/workflows/`. Sans volume, tout va directement dans `ComfyUI/`.
- **Dépendances Python** : le `requirements.txt` et le `install.py` des custom nodes, ainsi que
  les paquets `pip`, sont installés dans l'environnement Python du conteneur. Ils sont donc
  réinstallés automatiquement sur un nouveau pod, même si le volume est déjà peuplé.
- **Custom nodes déjà dans l'image** (ex. KJNodes) : laissés tels quels.
- Une clé inconnue (faute de frappe) fait échouer la commande avant toute action.

### Commandes

`/opt/scripts/comfy_profiles.py` sur le pod, piloté à distance par `deploy/07-sync-profiles.py` :

```bash
./07-sync-profiles.py list                     # profils disponibles
./07-sync-profiles.py show minimax-h3-all      # contenu d'un profil, et ce qui est déjà là
./07-sync-profiles.py sync krea2 --dry-run     # ce qui serait installé, sans rien faire
./07-sync-profiles.py sync krea2,flux2-klein   # installe sans redémarrer le pod
./07-sync-profiles.py                          # sync des profils COMFY_PROFILES de .env
```

Après une synchronisation à chaud, les nouveaux modèles apparaissent dans ComfyUI dès qu'on
rafraîchit la page (touche R). Les nouveaux custom nodes nécessitent un redémarrage de ComfyUI
(`runpodctl pod restart <pod-id>`). Pour qu'un profil soit installé à chaque nouveau pod,
ajoute-le à `COMFY_PROFILES` dans `.env`, puis relance `09-create-or-update-template.py` si tu
passes par le template.

`int8_convrot` est privilégié à `fp8_scaled`, sur recommandation de Comfy-Org (meilleure
qualité, CUDA 13.0 requis, ce qui est le cas ici).

⚠️ L'usage commercial des vidéos générées localement nécessite une licence commerciale
MiniMax (voir la doc du modèle).

## Build

Nécessite que `runpod-blackwell-base` ait été construit (ou poussé sur un registre) avant :

```bash
cd ../runpod-blackwell-base && ./build.sh && cd -
./build.sh
```

Pour builder contre une image de base déjà poussée (CI) :
```bash
BASE_IMAGE=ghcr.io/<user>/runpod-blackwell-base:latest ./build.sh
```

## Push

```bash
export REGISTRY=ghcr.io/<ton-user>
docker login ghcr.io
./push.sh
```

## CI (GitHub Actions)

`.github/workflows/build-push.yml` build et pousse l'image sur GHCR à chaque push sur `main`
touchant `Dockerfile`, `entrypoint.sh` ou `scripts/`, ou manuellement via l'onglet Actions.
Elle utilise par défaut `ghcr.io/<owner>/runpod-blackwell-base:latest` comme base — pense donc
à laisser tourner la CI du dépôt base avant celle-ci la première fois (ou lance-la manuellement
avec un `base_image` explicite via "Run workflow").

Le déclenchement manuel ("Run workflow") accepte deux paramètres optionnels :
- `comfyui_version` : pour tester/bumper une nouvelle version de ComfyUI sans toucher au code
  (ex: `v0.38.0`).
- `base_image` : pour builder contre une image de base précise plutôt que `:latest`.

Comme pour la base, rends le package GHCR public après le premier push (GitHub → Packages →
Package settings → Change visibility), sinon RunPod ne pourra pas puller l'image.

Tags publiés : `ghcr.io/<owner>/runpod-comfy-blackwell:latest` et `:sha-<commit-court>` — c'est
directement la valeur à mettre dans `IMAGE` de `deploy/.env`.

## Lancer un pod avec le CLI RunPod

Prérequis : [`runpodctl`](https://github.com/runpod/runpodctl) installé et une clé API RunPod.

Les scripts de `deploy/` sont en Python 3, bibliothèque standard uniquement (aucune dépendance à
installer). Ils lisent et écrivent tous `deploy/.env`.

`deploy/.env` accepte aussi `HF_TOKEN` (Hugging Face), `CIVITAI_TOKEN` (CivitAI, pour les
sources `civitai` des profils) et `JUPYTER_TOKEN`. Ils ne sont jamais passés
en clair au pod ni au template : `./10-create-or-update-secrets.py` les pousse dans les secrets
RunPod `hf_token`, `civitai_token` et `jupyter_token`. `02-start-pod.py` et le template y font
ensuite référence (`{{ RUNPOD_SECRET_hf_token }}`, etc.), et RunPod substitue les valeurs au
démarrage du pod. Dans le pod, ils sont persistés dans `/etc/environment` pour toute session SSH
ultérieure. Un secret déjà présent est conservé ; `--force` le remplace par la valeur de `.env`
(l'API RunPod ne permet pas de modifier un secret : il est supprimé puis recréé). `HF_TOKEN`
n'est pas obligatoire pour les dépôts publics utilisés ici, mais évite le rate-limit anonyme et
sera nécessaire si un dépôt devient gated.

```bash
cp deploy/env.example deploy/.env
$EDITOR deploy/.env        # renseigner RUNPOD_API_KEY, IMAGE, GPU_ID, DATA_CENTER_ID, HF_TOKEN...

cd deploy
./00-check-gpu-availability.py                    # stock GPU pour le DATA_CENTER_ID de .env
./00-check-gpu-availability.py US-KS-2 "6000|5090" # datacenter + filtre par nom (regex)
                                                    # le stock change en temps réel, à revérifier
                                                    # si "none" partout avant de créer le pod

./10-create-or-update-secrets.py  # une seule fois (ou --force après changement d'un token) :
                                  # pousse HF_TOKEN/CIVITAI_TOKEN/JUPYTER_TOKEN en secrets RunPod
./01-create-volume.py      # une seule fois : crée le Network Volume (250 Go par défaut)
./02-start-pod.py          # crée le pod (image + GPU + volume monté)
./07-sync-profiles.py      # optionnel : le pod installe déjà COMFY_PROFILES au démarrage ;
                            # list / show / sync <profil> : voir la section Profils ci-dessus

./06-ssh.py                # ouvrir un shell SSH sur le pod
./08-status.py             # état du pod
./03-stop-pod.py           # stopper (arrête la facturation GPU, garde le volume + le disque)
./04-resume-pod.py         # redémarrer le même pod (rapide, rien à re-télécharger)
./05-terminate-pod.py      # supprimer le pod définitivement (le volume survit)
```

`02-start-pod.py` affiche l'URL publique de ComfyUI et JupyterLab
(`https://<pod-id>-8188.proxy.runpod.net` et `-8888-`) dès qu'elles répondent vraiment (pas
juste à la création du pod : `--wait` n'attend que SSH, pas le démarrage des services). Timeout
par défaut 1 h (`URL_WAIT_TIMEOUT`), pour laisser le temps au premier téléchargement des profils sur un volume vide ; les URLs restent
aussi visibles dans l'onglet **Connect** de la console RunPod à tout moment.

**JupyterLab** (port 8888) tourne en plus de ComfyUI, protégé par un token (secret RunPod
`jupyter_token`, alimenté depuis `JUPYTER_TOKEN` de `.env` ; s'il est vide dans le pod, un token
est généré aléatoirement à chaque démarrage et visible dans les logs du pod).

**CORS/Host derrière le proxy RunPod** : par défaut ComfyUI et Jupyter rejettent (403) les
requêtes dont le Host ne correspond pas à leur IP interne — exactement ce que fait le proxy
RunPod (`https://<pod-id>-<port>.proxy.runpod.net`). `entrypoint.sh` détecte `RUNPOD_POD_ID`
(injecté automatiquement par RunPod) et passe `--enable-cors-header`/`--ServerApp.allow_origin`
avec l'origine exacte du pod pour éviter ça ; sans `RUNPOD_POD_ID` (tests locaux), il retombe sur
un wildcard `*`.

### Template RunPod (optionnel)

`./09-create-or-update-template.py` crée un template RunPod (image + ports + env + disque),
réutilisable depuis le dashboard RunPod ou avec `runpodctl pod create --template-id <id>`, sans
avoir à rappeler tous les flags à chaque fois. Idempotent : relancé, il retrouve le template par
`TEMPLATE_NAME` (ou par `TEMPLATE_ID` s'il est déjà connu dans `.env`) et le met à jour au lieu
d'en recréer un nouveau — pratique après un `git push` qui republie une nouvelle version de
l'image.

Les tokens n'apparaissent jamais en clair dans le template : `HF_TOKEN`, `CIVITAI_TOKEN` et
`JUPYTER_TOKEN` y référencent les secrets RunPod `{{ RUNPOD_SECRET_hf_token }}`,
`{{ RUNPOD_SECRET_civitai_token }}` et `{{ RUNPOD_SECRET_jupyter_token }}`, créés par
`./10-create-or-update-secrets.py` (voir plus haut) ou à la main dans le dashboard RunPod
(**Settings → Secrets**). Les ports exposés y sont libellés
« ComfyUI » (8188), « Jupyter Lab » (8888) et « SSH » (22).

```bash
./09-create-or-update-template.py
```

Vérifie la chaîne exacte du GPU sur ton compte avec `runpodctl gpu list | grep -i 6000`
avant le premier lancement (le nom peut varier légèrement selon les régions/offres).

## Notes Blackwell

- `SageAttention` (image de base) accélère l'attention (~2x). Dans ComfyUI, patcher le
  modèle avec le node **Patch Sage Attention KJ** (fourni par KJNodes, déjà installé).
- Les poids `int8_convrot` et `nvfp4_awq` tirent parti des tensor cores FP4/INT8 natifs de
  Blackwell — c'est pourquoi ils sont préférés à `bf16`/`fp8_scaled` par défaut ici.
