#!/usr/bin/env bash
# create_voice_clone_vm.sh
#
# Script de création automatique d'une VM Proxmox pour le clonage de voix
# avec XTTS v2 et Ollama
#
# Utilisation :
#   ./create_voice_clone_vm.sh [options]
#
# Options :
#   --vmid <id>           ID de la VM (par défaut: auto-détection)
#   --storage <name>      Stockage pour la VM (par défaut: local-lvm)
#   --iso <path>          Chemin vers l'ISO Ubuntu (par défaut: cherche automatiquement)
#   --memory <MB>         RAM en MB (par défaut: 8192)
#   --cores <num>         Nombre de cœurs CPU (par défaut: 4)
#   --disk <GB>           Taille du disque en GB (par défaut: 50)
#   --bridge <name>       Bridge réseau (par défaut: vmbr0)
#   --start               Démarrer la VM après création
#   -h, --help            Affiche cette aide

set -euo pipefail

# Couleurs pour l'affichage
if [[ -t 1 ]]; then
  COLOR_GREEN="\033[32m"
  COLOR_RED="\033[31m"
  COLOR_YELLOW="\033[33m"
  COLOR_BLUE="\033[34m"
  COLOR_BOLD="\033[1m"
  COLOR_DIM="\033[2m"
  COLOR_RESET="\033[0m"
else
  COLOR_GREEN=""
  COLOR_RED=""
  COLOR_YELLOW=""
  COLOR_BLUE=""
  COLOR_BOLD=""
  COLOR_DIM=""
  COLOR_RESET=""
fi

# Configuration par défaut
VM_NAME="voice_clone"
VM_MEMORY=8192      # 8GB RAM
VM_CORES=4          # 4 cœurs CPU
VM_DISK_SIZE=50     # 50GB disque
VM_STORAGE="local-lvm"
VM_BRIDGE="vmbr0"
VM_VMID=""
VM_ISO=""
START_VM=false

log() {
  printf '%s[%s]%s %s\n' "${COLOR_DIM}" "$(date '+%H:%M:%S')" "${COLOR_RESET}" "$*"
}

error() {
  printf '%s[ERREUR]%s %s\n' "${COLOR_RED}" "${COLOR_RESET}" "$*" >&2
}

success() {
  printf '%s[SUCCÈS]%s %s\n' "${COLOR_GREEN}" "${COLOR_RESET}" "$*"
}

warning() {
  printf '%s[ATTENTION]%s %s\n' "${COLOR_YELLOW}" "${COLOR_RESET}" "$*"
}

print_usage() {
  cat <<'EOF'
Usage : create_voice_clone_vm.sh [options]

Ce script crée une VM Proxmox optimisée pour le clonage de voix avec :
- Ubuntu 22.04 LTS ou 24.04 LTS
- 8GB RAM (configurable)
- 4 cœurs CPU (configurable) 
- 50GB disque (configurable)
- Configuration réseau automatique

Options disponibles :
  --vmid <id>           ID de la VM (par défaut: auto-détection du prochain ID libre)
  --storage <name>      Stockage pour la VM (par défaut: local-lvm)
  --iso <path>          Chemin vers l'ISO Ubuntu (par défaut: cherche automatiquement)
  --memory <MB>         RAM en MB (par défaut: 8192 = 8GB)
  --cores <num>         Nombre de cœurs CPU (par défaut: 4)
  --disk <GB>           Taille du disque en GB (par défaut: 50)
  --bridge <name>       Bridge réseau (par défaut: vmbr0)
  --start               Démarrer la VM après création
  -h, --help            Affiche cette aide

Exemples :
  # Création basique avec paramètres par défaut
  ./create_voice_clone_vm.sh

  # VM avec plus de ressources
  ./create_voice_clone_vm.sh --memory 16384 --cores 8 --disk 100

  # VM avec démarrage automatique
  ./create_voice_clone_vm.sh --start

  # VM avec stockage spécifique
  ./create_voice_clone_vm.sh --storage local-zfs --vmid 200
EOF
}

# Parse des arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)
      if [[ $# -lt 2 ]]; then
        error "L'option --vmid nécessite un argument (ID)."
        exit 1
      fi
      VM_VMID="$2"
      shift 2
      ;;
    --storage)
      if [[ $# -lt 2 ]]; then
        error "L'option --storage nécessite un argument (nom du stockage)."
        exit 1
      fi
      VM_STORAGE="$2"
      shift 2
      ;;
    --iso)
      if [[ $# -lt 2 ]]; then
        error "L'option --iso nécessite un argument (chemin vers l'ISO)."
        exit 1
      fi
      VM_ISO="$2"
      shift 2
      ;;
    --memory)
      if [[ $# -lt 2 ]]; then
        error "L'option --memory nécessite un argument (MB)."
        exit 1
      fi
      VM_MEMORY="$2"
      shift 2
      ;;
    --cores)
      if [[ $# -lt 2 ]]; then
        error "L'option --cores nécessite un argument (nombre)."
        exit 1
      fi
      VM_CORES="$2"
      shift 2
      ;;
    --disk)
      if [[ $# -lt 2 ]]; then
        error "L'option --disk nécessite un argument (GB)."
        exit 1
      fi
      VM_DISK_SIZE="$2"
      shift 2
      ;;
    --bridge)
      if [[ $# -lt 2 ]]; then
        error "L'option --bridge nécessite un argument (nom du bridge)."
        exit 1
      fi
      VM_BRIDGE="$2"
      shift 2
      ;;
    --start)
      START_VM=true
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      error "Option inconnue : $1"
      print_usage >&2
      exit 1
      ;;
  esac
  shift
done

check_prerequisites() {
  log "Vérification des prérequis..."
  
  # Vérifier qu'on est sur Proxmox
  if ! command -v qm >/dev/null 2>&1; then
    error "Ce script doit être exécuté sur un serveur Proxmox VE."
    error "La commande 'qm' n'est pas disponible."
    exit 1
  fi
  
  # Vérifier les privilèges root
  if [[ "${EUID}" -ne 0 ]]; then
    error "Ce script doit être exécuté avec les privilèges root (sudo)."
    exit 1
  fi
  
  success "Prérequis validés - Proxmox VE détecté"
}

find_next_vmid() {
  if [[ -n "${VM_VMID}" ]]; then
    log "Utilisation du VMID spécifié: ${VM_VMID}"
    # Vérifier que le VMID n'est pas déjà utilisé
    if qm status "${VM_VMID}" >/dev/null 2>&1; then
      error "Le VMID ${VM_VMID} est déjà utilisé."
      exit 1
    fi
    return
  fi
  
  log "Recherche du prochain VMID libre..."
  
  # Commencer à partir de 100 et trouver le premier ID libre
  for ((i=100; i<=999; i++)); do
    if ! qm status "$i" >/dev/null 2>&1; then
      VM_VMID="$i"
      break
    fi
  done
  
  if [[ -z "${VM_VMID}" ]]; then
    error "Impossible de trouver un VMID libre entre 100 et 999."
    exit 1
  fi
  
  success "VMID libre trouvé: ${VM_VMID}"
}

find_ubuntu_iso() {
  if [[ -n "${VM_ISO}" ]]; then
    log "Utilisation de l'ISO spécifié: ${VM_ISO}"
    if [[ ! -f "${VM_ISO}" ]]; then
      error "Le fichier ISO spécifié n'existe pas: ${VM_ISO}"
      exit 1
    fi
    return
  fi
  
  log "Recherche d'une ISO Ubuntu disponible..."
  
  # Chercher dans les emplacements communs
  local iso_paths=(
    "/var/lib/vz/template/iso"
    "/var/lib/vz/template/cache"
    "/mnt/pve/*/template/iso"
  )
  
  local found_iso=""
  for path in "${iso_paths[@]}"; do
    if [[ -d "${path}" ]]; then
      # Chercher des ISOs Ubuntu (22.04, 24.04)
      found_iso=$(find "${path}" -name "*ubuntu*22.04*.iso" -o -name "*ubuntu*24.04*.iso" | head -1)
      if [[ -n "${found_iso}" ]]; then
        break
      fi
    fi
  done
  
  if [[ -z "${found_iso}" ]]; then
    error "Aucune ISO Ubuntu 22.04 ou 24.04 trouvée."
    error "Veuillez télécharger une ISO Ubuntu et la placer dans /var/lib/vz/template/iso/"
    error "Ou spécifiez le chemin avec --iso <chemin>"
    exit 1
  fi
  
  VM_ISO="${found_iso}"
  success "ISO Ubuntu trouvée: ${VM_ISO}"
}

check_storage() {
  log "Vérification du stockage: ${VM_STORAGE}"
  
  if ! pvesm status -storage "${VM_STORAGE}" >/dev/null 2>&1; then
    error "Le stockage '${VM_STORAGE}' n'existe pas ou n'est pas disponible."
    log "Stockages disponibles:"
    pvesm status | grep -E "^[a-zA-Z]" | awk '{print "  - " $1}'
    exit 1
  fi
  
  success "Stockage validé: ${VM_STORAGE}"
}

create_vm() {
  log "Création de la VM '${VM_NAME}' (ID: ${VM_VMID})..."
  
  # Créer la VM avec la configuration optimisée pour le clonage de voix
  qm create "${VM_VMID}" \
    --name "${VM_NAME}" \
    --memory "${VM_MEMORY}" \
    --cores "${VM_CORES}" \
    --sockets 1 \
    --cpu host \
    --ostype l26 \
    --scsi0 "${VM_STORAGE}:${VM_DISK_SIZE}" \
    --scsihw virtio-scsi-pci \
    --bootdisk scsi0 \
    --net0 virtio,bridge="${VM_BRIDGE}" \
    --ide2 "${VM_ISO},media=cdrom" \
    --boot order=ide2 \
    --vga qxl \
    --tablet 1 \
    --agent enabled=1 \
    --description "VM optimisée pour le clonage de voix avec XTTS v2 et Ollama
    
Configuration:
- RAM: ${VM_MEMORY}MB ($(( VM_MEMORY / 1024 ))GB)
- CPU: ${VM_CORES} cœurs
- Disque: ${VM_DISK_SIZE}GB
- Réseau: ${VM_BRIDGE}
- OS: Ubuntu (via ${VM_ISO##*/})

Créée le $(date '+%Y-%m-%d %H:%M:%S') par create_voice_clone_vm.sh"

  success "VM '${VM_NAME}' créée avec succès (ID: ${VM_VMID})"
}

show_summary() {
  cat <<EOF

${COLOR_BOLD}=== VM '${VM_NAME}' créée avec succès ===${COLOR_RESET}

${COLOR_BLUE}Nom de la VM:${COLOR_RESET} ${VM_NAME}
${COLOR_BLUE}VMID:${COLOR_RESET} ${VM_VMID}
${COLOR_BLUE}RAM:${COLOR_RESET} ${VM_MEMORY}MB ($(( VM_MEMORY / 1024 ))GB)
${COLOR_BLUE}CPU:${COLOR_RESET} ${VM_CORES} cœurs
${COLOR_BLUE}Disque:${COLOR_RESET} ${VM_DISK_SIZE}GB sur ${VM_STORAGE}
${COLOR_BLUE}Réseau:${COLOR_RESET} ${VM_BRIDGE}
${COLOR_BLUE}ISO:${COLOR_RESET} ${VM_ISO##*/}

${COLOR_BOLD}⚠️  IMPORTANT: Cette VM est vide et doit être configurée${COLOR_RESET}

${COLOR_BOLD}Étapes suivantes obligatoires:${COLOR_RESET}

1. ${COLOR_GREEN}Démarrer la VM:${COLOR_RESET}
   qm start ${VM_VMID}

2. ${COLOR_GREEN}Ouvrir la console VM (pas le shell Proxmox!):${COLOR_RESET}
   - Via l'interface web: Datacenter > ${VM_NAME} > Console
   - Ou: qm terminal ${VM_VMID}

3. ${COLOR_GREEN}Installer Ubuntu dans la VM:${COLOR_RESET}
   - Suivre l'installation Ubuntu standard
   - Créer un utilisateur avec privilèges sudo
   - Installer openssh-server pour l'accès distant

4. ${COLOR_GREEN}Une fois Ubuntu installé DANS LA VM:${COLOR_RESET}
   Se connecter à la VM (pas à Proxmox!) et exécuter:
   
   curl -fsSL "https://raw.githubusercontent.com/Sdavid66/clone_voice/main/install_voice_stack.sh" \\
     | sudo bash -s -- --install-ollama --dir /opt/voice-stack

${COLOR_BOLD}⚠️  NE PAS exécuter le script d'installation sur l'hôte Proxmox!${COLOR_RESET}
${COLOR_BOLD}Il doit être exécuté DANS la VM après installation d'Ubuntu.${COLOR_RESET}

${COLOR_BOLD}Commandes de gestion VM:${COLOR_RESET}
- Démarrer: qm start ${VM_VMID}
- Arrêter: qm stop ${VM_VMID}
- Console: qm terminal ${VM_VMID}
- Statut: qm status ${VM_VMID}
- Supprimer: qm destroy ${VM_VMID}

EOF
}

main() {
  printf '%s=== Création VM Proxmox pour Clonage de Voix ===%s\n\n' "${COLOR_BOLD}" "${COLOR_RESET}"
  
  check_prerequisites
  find_next_vmid
  find_ubuntu_iso
  check_storage
  create_vm
  
  if [[ "${START_VM}" == "true" ]]; then
    log "Démarrage de la VM..."
    qm start "${VM_VMID}"
    success "VM démarrée"
  fi
  
  show_summary
}

main "$@"
