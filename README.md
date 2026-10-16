# runpod-comfy-blackwell

ComfyUI (dernière stable, v0.40.0) sur [runpod-blackwell-base](../runpod-blackwell-base),
pour RunPod avec une RTX PRO 6000 (Blackwell, 96 Go VRAM). Les modèles et custom nodes de chaque
usage (MiniMax H3, Krea 2, FLUX.2 [klein]...) sont décrits par des **profils** installés au
démarrage du pod (voir [Profils d'utilisation](#profils-dutilisation)).

Aucun poids de modèle dans l'image. Les modèles vivent sur un **Network Volume RunPod**
persistant, montés au démarrage du pod — l'image reste petite (quelques Go) et le pod
démarre vite, à chaque fois. Voir `deploy/` pour tout le cycle de vie via `runpodctl`.

## Architecture

```
runpod-blackwell-base (CUDA 13.2 / PyTorch 2.14 / SageAttention)
        │
        ▼
runpod-comfy-blackwell (ComfyUI v0.40.0 + Manager intégré (--enable-manager) + panneau Profils)
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

Les profils disponibles sont définis dans un `profiles.json` hébergé sur GitHub (par défaut
[comfyui-profiles-repo](https://github.com/jdelahayes/comfyui-profiles-repo/blob/main/profiles.json)) ;
`./07-sync-profiles.py list` les affiche avec leur description.

La taille de chaque profil (`extends` compris, custom nodes non comptés) est indiquée dans
`profiles.json`. Après avoir modifié ou ajouté un profil, recalcule-la avec `profile_sizes.py`
du dépôt [comfyui-profiles](https://github.com/jdelahayes/comfyui-profiles) (il interroge
Hugging Face / CivitAI sans rien télécharger), ou sur le pod avec le bouton **Recalculer les
tailles** du panneau Profils.

### Fichier de profils

Le **modèle** (`COMFY_PROFILES_SEED`, `/opt/scripts/profiles.json`) n'est pas dans l'image :
`entrypoint.sh` le télécharge à chaque démarrage du pod depuis `COMFY_PROFILES_URL` (par défaut
`https://github.com/jdelahayes/comfyui-profiles-repo/raw/refs/heads/main/profiles.json`). Une
copie est gardée sur le volume (`/runpod-volume/cache/profiles.json`) et reprise si le
téléchargement échoue. Le pod utilise ce modèle tant que tu n'as pas ton propre fichier.
Éditer, importer (fichier ou URL) ou recalculer les tailles depuis le panneau Profils crée ce fichier dans `ComfyUI/user/__comfy_profiles/profiles.json`,
donc sur le Network Volume (`user/` y est lié) : il survit aux pods et prend le relais du
modèle. **Revenir au modèle** dans le panneau le met de côté. Sans fichier à toi, les profils
poussés sur le dépôt de `COMFY_PROFILES_URL` arrivent au prochain démarrage du pod, sans
reconstruire l'image.

`COMFY_PROFILES_CONFIG` (optionnel) impose un autre fichier, par exemple
`/runpod-volume/config/profiles.json` : s'il n'existe pas encore, le modèle y est copié au
premier démarrage.

Le format (sources `hf`, `github`, `civitai`, `url`, custom nodes `git` / `gdrive`, `extends`,
`pip`...) est décrit dans le README de
[comfyui-profiles](https://github.com/jdelahayes/comfyui-profiles#format), avec un schéma JSON
pour l'autocomplétion dans un éditeur.

Spécificités du pod :

- **Destinations** : modèles dans `/runpod-volume/models/<type>/` (via le lien `models/`),
  custom nodes clonés dans `/runpod-volume/custom_nodes/` (`COMFY_PROFILES_NODES_STORE`) et
  liés dans `ComfyUI/custom_nodes/`, workflows dans `ComfyUI/user/default/workflows/`. Sans
  volume, tout va directement dans `ComfyUI/`, perdu avec le pod.
- **Dépendances Python** : installées dans le venv du conteneur, donc réinstallées
  automatiquement sur un nouveau pod, même si le volume est déjà peuplé.
- **Custom nodes hors profils** : les vrais dossiers de `ComfyUI/custom_nodes/` (installés à la
  main ou par le Manager) ne sont jamais touchés par le gestionnaire. comfyui-profiles lui-même
  n'est pas un node de profil : voir [Panneau Profils](#panneau-profils-dans-comfyui).
- **Zips Drive chiffrés** : mot de passe `GDRIVE_ZIP_PASSWORD` de `deploy/.env` (secret RunPod
  `gdrive_zip_password`).

### Commandes

`/opt/scripts/comfy_profiles.py` sur le pod, piloté à distance par `deploy/07-sync-profiles.py` :

```bash
./07-sync-profiles.py list                     # profils disponibles
./07-sync-profiles.py show minimax-h3-all-pruned_int8  # contenu d'un profil, et ce qui est déjà là
./07-sync-profiles.py sync krea2 --dry-run     # ce qui serait installé, sans rien faire
./07-sync-profiles.py sync krea2,flux2-klein-9b # installe sans redémarrer le pod
./07-sync-profiles.py uninstall krea2 --dry-run # ce qui serait supprimé (le partagé est gardé)
./07-sync-profiles.py                          # sync des profils COMFY_PROFILES de .env
```

Après une synchronisation à chaud, les nouveaux modèles apparaissent dans ComfyUI dès qu'on
rafraîchit la page (touche R). Les nouveaux custom nodes nécessitent un redémarrage de ComfyUI
(`runpodctl pod restart <pod-id>`). Pour qu'un profil soit installé à chaque nouveau pod,
ajoute-le à `COMFY_PROFILES` dans `.env`, puis relance `09-create-or-update-template.py` si tu
passes par le template.

### Panneau Profils dans ComfyUI

Le gestionnaire de profils (`comfy_profiles.py`) et le panneau **Profils** de la barre
latérale de ComfyUI vivent dans un dépôt séparé,
[jdelahayes/comfyui-profiles](https://github.com/jdelahayes/comfyui-profiles) (voir son README).
Il n'est pas dans l'image : `entrypoint.sh` l'installe à chaque démarrage du pod, à la version
`COMFYUI_PROFILES_REF` de `deploy/.env` (tag ou branche ; vide = `latest`, le dernier tag
`vX.Y.Z` publié). Il est cloné sur le Network Volume (`/runpod-volume/comfyui-profiles`, mis à
jour par un `git fetch` aux démarrages suivants), puis lié dans `custom_nodes/comfyui-profiles`
et en `/opt/scripts/comfy_profiles.py`. Une nouvelle version du plugin arrive donc au prochain
démarrage, sans reconstruire l'image. Si GitHub est injoignable, la copie du volume sert telle
quelle ; sans copie (volume neuf), ComfyUI démarre sans panneau Profils ni synchronisation des
profils. Pour figer la version : `COMFYUI_PROFILES_REF="v0.6.1"`, puis
`09-create-or-update-template.py` si tu passes par le template.

Le panneau fait la même chose que `07-sync-profiles.py`, sans passer par SSH : état de chaque
profil (vert installé, orange partiel), installation, désinstallation, arrêt d'une action en
cours, édition, import et export de `profiles.json`, et redémarrage de ComfyUI (nécessaire
après l'installation de nouveaux custom nodes). Le fichier modifié est gardé sur le Network
Volume (voir *Fichier de profils*).

La désinstallation (`comfy_profiles.py uninstall PROFIL[,...] [--with-extends] [--dry-run]`)
supprime les modèles, workflows et custom nodes propres aux profils, **sauf** ce qui sert
encore à un profil gardé : un profil de `COMFY_PROFILES`, ou un autre profil complètement
installé, y compris ceux dont ils héritent. Exemple : désinstaller `krea2` garde le text
encoder et le VAE de `krea2-common`. `--with-extends` (case « Inclure les profils hérités »
du panneau) désinstalle aussi les profils hérités, par exemple pour `minimax-h3-all-*`, qui ne
fait que regrouper d'autres profils. Seul ce que le gestionnaire a installé lui-même est supprimé (manifeste
`user/__comfy_profiles/installed.json`, repris du contenu du volume au premier démarrage avec
comfyui-profiles v0.3.0) : les custom nodes de l'image, les fichiers copiés à la main et les
paquets pip restent. Un profil de `COMFY_PROFILES` désinstallé revient au prochain démarrage
du pod.

`int8_convrot` est privilégié à `fp8_scaled`, sur recommandation de Comfy-Org (meilleure
qualité, CUDA ≥ 13.0 requis, ce qui est le cas ici avec 13.2).

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
sources `civitai` des profils), `JUPYTER_TOKEN` et `GDRIVE_ZIP_PASSWORD` (zips chiffrés des
custom nodes `gdrive`). Ils ne sont jamais passés
en clair au pod ni au template : `./10-create-or-update-secrets.py` les pousse dans les secrets
RunPod `hf_token`, `civitai_token`, `jupyter_token` et `gdrive_zip_password`. `02-start-pod.py` et le template y font
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
                                  # pousse les tokens et GDRIVE_ZIP_PASSWORD de .env en secrets RunPod
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

Les tokens n'apparaissent jamais en clair dans le template : `HF_TOKEN`, `CIVITAI_TOKEN`,
`JUPYTER_TOKEN` et `GDRIVE_ZIP_PASSWORD` y référencent les secrets RunPod
`{{ RUNPOD_SECRET_hf_token }}`, `{{ RUNPOD_SECRET_civitai_token }}`,
`{{ RUNPOD_SECRET_jupyter_token }}` et `{{ RUNPOD_SECRET_gdrive_zip_password }}`, créés par
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
  modèle avec le node **Patch Sage Attention KJ** (fourni par KJNodes, installé par le profil
  `comfyui-common`, dont héritent les profils minimax, krea2 et flux2).
- Les poids `int8_convrot` et `nvfp4_awq` tirent parti des tensor cores FP4/INT8 natifs de
  Blackwell — c'est pourquoi ils sont préférés à `bf16`/`fp8_scaled` par défaut ici.
