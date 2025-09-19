# Déploiement automatisé de T-Pot via ISO Proxmox

Ce dépôt fournit également la commande à exécuter pour créer une VM Proxmox qui boote sur l'ISO officiel T-Pot.
Le provisioning s'appuie sur le script [`tpot_iso_provision.sh`](https://github.com/Sdavid66/proxmox-honeypot/blob/main/tpot_iso_provision.sh).

## Prérequis

- Accès shell à un nœud Proxmox avec les droits administrateur.
- `curl` et `jq` installés (voir commande ci-dessous pour l'installation de `jq`).
- Un stockage Proxmox disponible pour le disque (`local-lvm` dans l'exemple) et pour l'ISO (`local`).
- Un bridge réseau configuré (`vmbr0` par défaut sur Proxmox).

## Exécution directe depuis GitHub

```bash
apt-get update && apt-get install -y jq
bash <(curl -fsSL "https://raw.githubusercontent.com/Sdavid66/proxmox-honeypot/main/tpot_iso_provision.sh?nocache=$(date +%s)") \
  --name tpot-iso \
  --storage local-lvm \
  --iso-storage local \
  --bridge vmbr0 \
  --disk 256G \
  --memory 16384 \
  --cores 4 \
  --latest \
  --start
```

### Paramètres principaux

- `--name` : nom de la VM Proxmox à créer.
- `--storage` : stockage cible pour le disque virtuel.
- `--iso-storage` : stockage où l'ISO T-Pot sera téléchargée.
- `--bridge` : bridge réseau utilisé par la VM.
- `--disk` : taille du disque (ex. `256G`).
- `--memory` : quantité de RAM en MiB.
- `--cores` : nombre de vCPU.
- `--latest` : télécharge automatiquement la dernière ISO disponible (requiert `jq`).
- `--start` : démarre la VM immédiatement après création.

Consultez `bash <(curl ... ) --help` pour voir tous les paramètres disponibles.
