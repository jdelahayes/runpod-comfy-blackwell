# runpod-comfy-blackwell

ComfyUI (dernière stable, v0.37.2) sur [runpod-blackwell-base](../runpod-blackwell-base),
prêt pour MiniMax H3 sur RunPod avec une RTX PRO 6000 (Blackwell, 96 Go VRAM).

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
Network Volume RunPod  →  ComfyUI/models/{diffusion_models,text_encoders,vae,loras}
   (poids MiniMax H3,      (liens symboliques créés par entrypoint.sh)
    turbo + qualité max)
```

## MiniMax H3 : modèles par tag, config JSON éditable

[MiniMax H3](https://huggingface.co/Comfy-Org/MiniMax-H3) (sorti le 31/07/2026, poids ouverts,
support natif ComfyUI depuis la v0.30.0) génère de la vidéo 2K/15s avec audio stéréo natif à
partir de texte/image/vidéo/audio de référence.

Les modèles à télécharger sont décrits dans `scripts/models.json` (embarqué dans l'image en
`/opt/scripts/models.json`), chacun avec un `id` unique et une liste de `tags`. Le téléchargement
se fait par `scripts/download_models.py`, qui sélectionne soit par tag (`--tag`), soit par id
précis (`--id`), depuis ce fichier par défaut ou un fichier custom (`--config`) :

```bash
./07-download-models.sh --list                # explorer les modeles/tags disponibles sur le pod
./07-download-models.sh                        # tag MODEL_TAGS de .env (defaut: turbo)
./07-download-models.sh --tag hq               # un tag precis
./07-download-models.sh --id lora-fl2v-8step   # un seul modele par id
./07-download-models.sh --tag turbo,compact    # cumule plusieurs tags
```

Tags fournis par défaut :

| Tag | Contenu | Usage |
|---|---|---|
| `turbo` (défaut) | FL2VA/Ref2VA `int8_convrot` non-pruned + LoRA turbo LightX2V (4 et 8 steps) | Rendu rapide (4-8 steps), fonctionne tel quel avec le workflow ComfyUI par défaut — c'est la même base que celui-ci attend. |
| `hq` | Même base non-pruned, sans LoRA | Rendu qualité max, tous les steps, plus lent. |
| `compact` | Variante `pruned` (un peu plus légère) + LoRA HyperFlow 8 steps | Empreinte disque minimale, mais nécessite un sampler custom (Euler + scheduler normal + sigmas manuels — voir la `description` de `lora-hyperflow-8step` dans `models.json`). À ne PAS mélanger avec les LoRA `turbo` (LightX2V), qui exigent la base non-pruned. |

`int8_convrot` est privilégié à `fp8_scaled` sur les recommandations officielles Comfy-Org
(meilleure qualité) dès lors qu'on est sur CUDA 13.0 — ce qui est le cas ici.

Pour ajouter un modèle : éditer `scripts/models.json` (ou fournir ton propre fichier via
`--config`), avec `id`, `tags`, `repo` (dépôt Hugging Face), `files` (chemins dans le dépôt) et
optionnellement `local_subdir` (sous-dossier de destination, ex: `loras`).

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

Chaque script existe en deux versions équivalentes dans `deploy/` : `NN-nom.sh` (bash + `jq`)
et `NN-nom.py` (Python 3 stdlib uniquement — pas de dépendance à installer). Les deux lisent/
écrivent le même `deploy/.env`, utilise celle qui te convient. Les exemples ci-dessous utilisent
les `.sh` ; remplace juste l'extension pour la version Python (`./02-start-pod.py`, etc.).

`deploy/.env` accepte aussi `HF_TOKEN` (Hugging Face), `CIVITAI_TOKEN` (CivitAI, câblé en
prévision — aucun script actuel ne l'utilise encore) et `JUPYTER_TOKEN`. Ils ne sont jamais passés
en clair au pod ni au template : `./10-create-or-update-secrets.sh` les pousse dans les secrets
RunPod `hf_token`, `civitai_token` et `jupyter_token`. `02-start-pod.sh` et le template y font
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
./00-check-gpu-availability.sh                    # stock GPU pour le DATA_CENTER_ID de .env
./00-check-gpu-availability.sh US-KS-2 "6000|5090" # datacenter + filtre par nom (regex)
                                                    # le stock change en temps réel, à revérifier
                                                    # si "none" partout avant de créer le pod

./10-create-or-update-secrets.sh  # une seule fois (ou --force après changement d'un token) :
                                  # pousse HF_TOKEN/CIVITAI_TOKEN/JUPYTER_TOKEN en secrets RunPod
./01-create-volume.sh      # une seule fois : crée le Network Volume (250 Go par défaut)
./02-start-pod.sh          # crée le pod (image + GPU + volume monté)
./07-download-models.sh    # une seule fois : peuple le volume (tag MODEL_TAGS de .env, defaut turbo)
                            # --tag hq / --id <id> / --list : voir la section MiniMax H3 ci-dessus

./06-ssh.sh                # ouvrir un shell SSH sur le pod
./08-status.sh             # état du pod
./03-stop-pod.sh           # stopper (arrête la facturation GPU, garde le volume + le disque)
./04-resume-pod.sh         # redémarrer le même pod (rapide, rien à re-télécharger)
./05-terminate-pod.sh      # supprimer le pod définitivement (le volume survit)
```

`02-start-pod.sh` affiche l'URL publique de ComfyUI et JupyterLab
(`https://<pod-id>-8188.proxy.runpod.net` et `-8888-`) dès qu'elles répondent vraiment (pas
juste à la création du pod : `--wait` n'attend que SSH, pas le démarrage des services). Timeout
par défaut 15 min (`URL_WAIT_TIMEOUT`, plus long si `MODELS_AUTO_DOWNLOAD=1`) ; les URLs restent
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

`./09-create-or-update-template.sh` crée un template RunPod (image + ports + env + disque),
réutilisable depuis le dashboard RunPod ou avec `runpodctl pod create --template-id <id>`, sans
avoir à rappeler tous les flags à chaque fois. Idempotent : relancé, il retrouve le template par
`TEMPLATE_NAME` (ou par `TEMPLATE_ID` s'il est déjà connu dans `.env`) et le met à jour au lieu
d'en recréer un nouveau — pratique après un `git push` qui republie une nouvelle version de
l'image. Nécessite `jq`.

Les tokens n'apparaissent jamais en clair dans le template : `HF_TOKEN`, `CIVITAI_TOKEN` et
`JUPYTER_TOKEN` y référencent les secrets RunPod `{{ RUNPOD_SECRET_hf_token }}`,
`{{ RUNPOD_SECRET_civitai_token }}` et `{{ RUNPOD_SECRET_jupyter_token }}`, créés par
`./10-create-or-update-secrets.sh` (voir plus haut) ou à la main dans le dashboard RunPod
(**Settings → Secrets**). Les ports exposés y sont libellés
« ComfyUI » (8188), « Jupyter Lab » (8888) et « SSH » (22).

```bash
./09-create-or-update-template.sh
```

Vérifie la chaîne exacte du GPU sur ton compte avec `runpodctl gpu list | grep -i 6000`
avant le premier lancement (le nom peut varier légèrement selon les régions/offres).

## Notes Blackwell

- `SageAttention` (image de base) accélère l'attention (~2x). Dans ComfyUI, patcher le
  modèle avec le node **Patch Sage Attention KJ** (fourni par KJNodes, déjà installé).
- Les poids `int8_convrot` et `nvfp4_awq` tirent parti des tensor cores FP4/INT8 natifs de
  Blackwell — c'est pourquoi ils sont préférés à `bf16`/`fp8_scaled` par défaut ici.
