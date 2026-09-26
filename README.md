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
runpod-comfy-blackwell (ComfyUI v0.37.2 + Manager + KJNodes)
        │
        ▼  (au démarrage du pod)
Network Volume RunPod  →  ComfyUI/models/{diffusion_models,text_encoders,vae,loras}
   (poids MiniMax H3,      (liens symboliques créés par entrypoint.sh)
    turbo + qualité max)
```

## MiniMax H3 : turbo pour itérer, qualité max pour le rendu final

[MiniMax H3](https://huggingface.co/Comfy-Org/MiniMax-H3) (sorti le 31/07/2026, poids ouverts,
support natif ComfyUI depuis la v0.30.0) génère de la vidéo 2K/15s avec audio stéréo natif à
partir de texte/image/vidéo/audio de référence.

Deux jeux de poids sont téléchargés par `scripts/download_models.sh` :

- **Kit turbo** (par défaut) : diffusion models `pruned + int8_convrot` (~42 Go) + LoRA turbo
  4-8 steps (`drbaph/MiniMax-H3-Turbo-Lora-ComfyUI`). Génère en quelques secondes → pour valider
  rapidement un prompt/composition.
- **Qualité maximale** (`DOWNLOAD_FULL_QUALITY=1`) : diffusion models non-pruned `int8_convrot`
  (sans LoRA turbo, tous les steps). Plus lent, à réserver au rendu final une fois le prompt
  validé avec le kit turbo.

`int8_convrot` est privilégié à `fp8_scaled` sur les recommandations officielles Comfy-Org
(meilleure qualité) dès lors qu'on est sur CUDA 13.0 — ce qui est le cas ici.

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

```bash
cp deploy/env.example deploy/.env
$EDITOR deploy/.env        # renseigner RUNPOD_API_KEY, IMAGE, GPU_ID, DATA_CENTER_ID...

cd deploy
./01-create-volume.sh      # une seule fois : crée le Network Volume (250 Go par défaut)
./02-start-pod.sh          # crée le pod (image + GPU + volume monté)
./07-download-models.sh    # une seule fois : peuple le volume (kit turbo)
                            # DOWNLOAD_FULL_QUALITY=1 dans .env pour aussi tirer la qualité max

./06-ssh.sh                # ouvrir un shell SSH sur le pod
./08-status.sh             # état du pod
./03-stop-pod.sh           # stopper (arrête la facturation GPU, garde le volume + le disque)
./04-resume-pod.sh         # redémarrer le même pod (rapide, rien à re-télécharger)
./05-terminate-pod.sh      # supprimer le pod définitivement (le volume survit)
```

ComfyUI est ensuite accessible via l'onglet **Connect** du pod dans la console RunPod,
sur le port `8188` (HTTP).

Vérifie la chaîne exacte du GPU sur ton compte avec `runpodctl gpu list | grep -i 6000`
avant le premier lancement (le nom peut varier légèrement selon les régions/offres).

## Notes Blackwell

- `SageAttention` (image de base) accélère l'attention (~2x). Dans ComfyUI, patcher le
  modèle avec le node **Patch Sage Attention KJ** (fourni par KJNodes, déjà installé).
- Les poids `int8_convrot` et `nvfp4_awq` tirent parti des tensor cores FP4/INT8 natifs de
  Blackwell — c'est pourquoi ils sont préférés à `bf16`/`fp8_scaled` par défaut ici.
