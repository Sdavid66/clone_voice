#!/usr/bin/env bash
# cleanup_proxmox_host.sh
#
# Script de nettoyage pour supprimer les installations accidentelles
# de la stack de clonage de voix sur l'hôte Proxmox
#
# Utilisation :
#   ./cleanup_proxmox_host.sh [--force]

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

FORCE_CLEANUP=false

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
Usage : cleanup_proxmox_host.sh [--force]

Ce script nettoie les installations accidentelles de la stack de clonage 
de voix qui ont été faites sur l'hôte Proxmox au lieu d'une VM.

Actions effectuées :
- Arrêt et suppression des conteneurs Docker XTTS
- Suppression des répertoires voice-stack
- Nettoyage des images Docker inutilisées
- Désinstallation d'Ollama (optionnel)

Options :
  --force    Exécute le nettoyage sans demander confirmation
  -h, --help Affiche cette aide

ATTENTION : Ce script ne doit être utilisé QUE sur l'hôte Proxmox
pour nettoyer une installation accidentelle.
EOF
}

# Parse des arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE_CLEANUP=true
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
  log "Vérification de l'environnement..."
  
  # Vérifier qu'on est bien sur Proxmox
  if [[ ! -f /etc/pve/.version ]] && ! command -v qm >/dev/null 2>&1; then
    error "Ce script doit être exécuté sur un hôte Proxmox VE."
    exit 1
  fi
  
  # Vérifier les privilèges root
  if [[ "${EUID}" -ne 0 ]]; then
    error "Ce script doit être exécuté avec les privilèges root (sudo)."
    exit 1
  fi
  
  success "Environnement Proxmox VE détecté"
}

confirm_cleanup() {
  if [[ "${FORCE_CLEANUP}" == "true" ]]; then
    return 0
  fi
  
  cat <<EOF

${COLOR_BOLD}=== NETTOYAGE DE L'HÔTE PROXMOX ===${COLOR_RESET}

${COLOR_YELLOW}Ce script va supprimer les éléments suivants de l'hôte Proxmox :${COLOR_RESET}

1. Conteneurs Docker XTTS (arrêt et suppression)
2. Répertoires voice-stack dans /root et /opt
3. Images Docker inutilisées
4. Ollama (si installé accidentellement)

${COLOR_RED}ATTENTION : Cette action est irréversible !${COLOR_RESET}

EOF

  read -p "Voulez-vous continuer ? (oui/non) : " -r
  if [[ ! $REPLY =~ ^[Oo][Uu][Ii]$ ]]; then
    log "Nettoyage annulé par l'utilisateur"
    exit 0
  fi
}

cleanup_docker_containers() {
  log "Nettoyage des conteneurs Docker XTTS..."
  
  # Arrêter et supprimer les conteneurs XTTS
  if command -v docker >/dev/null 2>&1; then
    # Rechercher les conteneurs liés à XTTS
    local containers
    containers=$(docker ps -a --filter "name=xtts" --format "{{.Names}}" 2>/dev/null || true)
    
    if [[ -n "${containers}" ]]; then
      log "Arrêt des conteneurs XTTS..."
      echo "${containers}" | xargs -r docker stop 2>/dev/null || true
      
      log "Suppression des conteneurs XTTS..."
      echo "${containers}" | xargs -r docker rm 2>/dev/null || true
      
      success "Conteneurs XTTS supprimés"
    else
      log "Aucun conteneur XTTS trouvé"
    fi
    
    # Nettoyer les images Docker inutilisées
    log "Nettoyage des images Docker inutilisées..."
    docker image prune -f >/dev/null 2>&1 || true
    docker volume prune -f >/dev/null 2>&1 || true
    
    success "Images et volumes Docker nettoyés"
  else
    log "Docker n'est pas installé, rien à nettoyer"
  fi
}

cleanup_directories() {
  log "Suppression des répertoires voice-stack..."
  
  local directories=(
    "/root/voice-stack"
    "/opt/voice-stack"
    "/home/*/voice-stack"
  )
  
  local found=false
  for dir in "${directories[@]}"; do
    if [[ -d "${dir}" ]]; then
      log "Suppression de ${dir}..."
      rm -rf "${dir}"
      found=true
    fi
  done
  
  if [[ "${found}" == "true" ]]; then
    success "Répertoires voice-stack supprimés"
  else
    log "Aucun répertoire voice-stack trouvé"
  fi
}

cleanup_ollama() {
  log "Vérification d'Ollama..."
  
  if command -v ollama >/dev/null 2>&1; then
    warning "Ollama est installé sur l'hôte Proxmox"
    
    if [[ "${FORCE_CLEANUP}" == "true" ]]; then
      local remove_ollama="oui"
    else
      read -p "Voulez-vous supprimer Ollama ? (oui/non) : " -r remove_ollama
    fi
    
    if [[ $remove_ollama =~ ^[Oo][Uu][Ii]$ ]]; then
      log "Arrêt du service Ollama..."
      systemctl stop ollama 2>/dev/null || true
      systemctl disable ollama 2>/dev/null || true
      
      log "Suppression d'Ollama..."
      rm -f /usr/local/bin/ollama
      rm -rf /usr/share/ollama
      rm -f /etc/systemd/system/ollama.service
      systemctl daemon-reload
      
      # Supprimer les modèles Ollama
      rm -rf /root/.ollama 2>/dev/null || true
      rm -rf /home/*/.ollama 2>/dev/null || true
      
      success "Ollama supprimé"
    else
      log "Ollama conservé"
    fi
  else
    log "Ollama n'est pas installé"
  fi
}

show_summary() {
  cat <<EOF

${COLOR_BOLD}=== NETTOYAGE TERMINÉ ===${COLOR_RESET}

${COLOR_GREEN}L'hôte Proxmox a été nettoyé avec succès.${COLOR_RESET}

${COLOR_BOLD}Prochaines étapes recommandées :${COLOR_RESET}

1. ${COLOR_BLUE}Créer une VM dédiée :${COLOR_RESET}
   curl -fsSL "https://raw.githubusercontent.com/Sdavid66/clone_voice/main/create_voice_clone_vm.sh" \\
     | sudo bash -s --

2. ${COLOR_BLUE}Installer Ubuntu dans la VM${COLOR_RESET}

3. ${COLOR_BLUE}Installer la stack de clonage DANS LA VM :${COLOR_RESET}
   curl -fsSL "https://raw.githubusercontent.com/Sdavid66/clone_voice/main/install_voice_stack.sh" \\
     | sudo bash -s -- --install-ollama --dir /opt/voice-stack

${COLOR_YELLOW}Rappel : Ne jamais installer la stack de clonage de voix sur l'hôte Proxmox !${COLOR_RESET}

EOF
}

main() {
  echo -e "${COLOR_BOLD}=== Nettoyage de l'hôte Proxmox ===${COLOR_RESET}\n"
  
  check_prerequisites
  confirm_cleanup
  
  cleanup_docker_containers
  cleanup_directories
  cleanup_ollama
  
  show_summary
}

main "$@"
