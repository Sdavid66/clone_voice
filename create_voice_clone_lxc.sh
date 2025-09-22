#!/usr/bin/env bash
# create_voice_clone_lxc.sh
#
# Script de création et installation automatique d'un conteneur LXC Proxmox 
# pour le clonage de voix avec XTTS v2 et Ollama
#
# Ce script fait TOUT automatiquement :
# 1. Crée le conteneur LXC Proxmox
# 2. Démarre le conteneur
# 3. Installe Ubuntu et la stack de clonage de voix
#
# Utilisation :
#   ./create_voice_clone_lxc.sh [options]

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
CT_NAME="voice-clone-lxc"
CT_MEMORY=4096       # 4GB RAM (suffisant pour LXC)
CT_CORES=4           # 4 cœurs CPU
CT_DISK_SIZE=50      # 50GB disque (nécessaire pour TTS + dépendances)
CT_STORAGE="local-lvm"
CT_BRIDGE="vmbr0"
CT_VMID=""
CT_PASSWORD="VoiceClone2024!"

log() {
  printf '%s[%s] [CT:%s]%s %s\n' "${COLOR_GREEN}" "$(date '+%H:%M:%S')" "${CT_VMID:-"---"}" "${COLOR_RESET}" "$*"
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
Usage : create_voice_clone_lxc.sh [options]

Ce script crée et configure automatiquement un conteneur LXC Proxmox 
pour le clonage de voix avec installation complète de la stack XTTS.

Options disponibles :
  --vmid <id>           ID du conteneur (par défaut: auto-détection)
  --storage <name>      Stockage pour le conteneur (par défaut: local-lvm)
  --memory <MB>         RAM en MB (par défaut: 4096 = 4GB)
  --cores <num>         Nombre de cœurs CPU (par défaut: 4)
  --disk <GB>           Taille du disque en GB (par défaut: 30)
  --bridge <name>       Bridge réseau (par défaut: vmbr0)
  --password <pass>     Mot de passe root (par défaut: VoiceClone2024!)
  -h, --help            Affiche cette aide

Exemples :
  # Installation complète automatique
  ./create_voice_clone_lxc.sh

  # Avec paramètres personnalisés
  ./create_voice_clone_lxc.sh --memory 8192 --cores 8 --password MonMotDePasse

  # Avec VMID spécifique
  ./create_voice_clone_lxc.sh --vmid 300
EOF
}

# Parse des arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)
      CT_VMID="$2"; shift 2 ;;
    --storage)
      CT_STORAGE="$2"; shift 2 ;;
    --memory)
      CT_MEMORY="$2"; shift 2 ;;
    --cores)
      CT_CORES="$2"; shift 2 ;;
    --disk)
      CT_DISK_SIZE="$2"; shift 2 ;;
    --bridge)
      CT_BRIDGE="$2"; shift 2 ;;
    --password)
      CT_PASSWORD="$2"; shift 2 ;;
    -h|--help)
      print_usage; exit 0 ;;
    *)
      error "Option inconnue : $1"; print_usage >&2; exit 1 ;;
  esac
done

check_prerequisites() {
  log "Vérification des prérequis..."
  
  if ! command -v pct >/dev/null 2>&1; then
    error "Ce script doit être exécuté sur un serveur Proxmox VE."
    exit 1
  fi
  
  if [[ "${EUID}" -ne 0 ]]; then
    error "Ce script doit être exécuté avec les privilèges root (sudo)."
    exit 1
  fi
  
  success "Prérequis validés - Proxmox VE détecté"
}

find_next_vmid() {
  if [[ -n "${CT_VMID}" ]]; then
    log "Utilisation du VMID spécifié: ${CT_VMID}"
    if pct status "${CT_VMID}" >/dev/null 2>&1 || qm status "${CT_VMID}" >/dev/null 2>&1; then
      error "Le VMID ${CT_VMID} est déjà utilisé."
      exit 1
    fi
    return
  fi
  
  log "Recherche du prochain VMID libre..."
  
  local existing_vmids
  existing_vmids=$(
    {
      qm list 2>/dev/null | awk 'NR>1 {print $1}'
      pct list 2>/dev/null | awk 'NR>1 {print $1}'
    } | sort -n | uniq
  )
  
  for ((i=300; i<=399; i++)); do
    if ! echo "${existing_vmids}" | grep -q "^${i}$"; then
      CT_VMID="$i"
      break
    fi
  done
  
  if [[ -z "${CT_VMID}" ]]; then
    error "Impossible de trouver un VMID libre entre 300 et 399."
    exit 1
  fi
  
  success "VMID libre trouvé: ${CT_VMID}"
}

download_ubuntu_template() {
  log "Vérification du template Ubuntu..."
  
  # Vérifier si le template existe déjà
  if pveam list local | grep -q "ubuntu-22.04-standard"; then
    success "Template Ubuntu 22.04 déjà disponible"
    return
  fi
  
  log "Téléchargement du template Ubuntu 22.04..."
  pveam update
  pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst
  
  success "Template Ubuntu 22.04 téléchargé"
}

create_lxc_container() {
  log "Création du conteneur LXC '${CT_NAME}' (ID: ${CT_VMID})..."
  
  # Créer le conteneur avec configuration de base
  pct create "${CT_VMID}" \
    local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
    --hostname "${CT_NAME}" \
    --memory "${CT_MEMORY}" \
    --cores "${CT_CORES}" \
    --rootfs "${CT_STORAGE}:${CT_DISK_SIZE}" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
    --password "${CT_PASSWORD}" \
    --unprivileged 0 \
    --onboot 1 \
    --description "Conteneur LXC pour clonage de voix avec XTTS v2 et Ollama"
  
  # Configuration Docker après création du conteneur
  log "Configuration Docker et privilèges pour le conteneur..."
  
  # Ajouter les configurations nécessaires pour Docker
  cat >> "/etc/pve/lxc/${CT_VMID}.conf" << EOF
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
EOF

  success "Conteneur LXC créé avec succès (ID: ${CT_VMID})"
}

start_and_install() {
  log "🚀 Démarrage du conteneur CT:${CT_VMID} et installation de la stack..."
  
  # Démarrer le conteneur
  log "📋 Démarrage du conteneur LXC..."
  pct start "${CT_VMID}"
  
  # Attendre que le conteneur soit prêt avec vérification
  log "⏱️ Attente du démarrage complet du conteneur (15s)..."
  sleep 15
  
  # Vérifier que le conteneur est bien démarré
  if ! pct status "${CT_VMID}" | grep -q "running"; then
    error "Le conteneur n'a pas démarré correctement"
    exit 1
  fi
  
  log "✅ Conteneur démarré avec succès"
  
  log "📦 Mise à jour des paquets du système..."
  pct exec "${CT_VMID}" -- apt update -y
  
  log "📦 Installation des dépendances de base..."
  pct exec "${CT_VMID}" -- apt install -y curl wget git htop nano
  
  log "🌐 Obtention de l'IP du conteneur..."
  local ct_ip
  ct_ip=$(pct exec "${CT_VMID}" -- hostname -I | awk '{print $1}' || echo "")
  if [[ -n "$ct_ip" ]]; then
    log "🌐 IP du conteneur: $ct_ip"
  else
    warning "IP du conteneur non détectée"
  fi
  
  log "🚀 Téléchargement du script d'installation de la stack..."
  pct exec "${CT_VMID}" -- bash -c "
    echo '=== DÉBUT INSTALLATION STACK - $(date) ===' > /tmp/voice-install.log
    echo 'Téléchargement du script...' >> /tmp/voice-install.log
    curl -fsSL 'https://raw.githubusercontent.com/Sdavid66/clone_voice/main/install_voice_stack.sh' -o /tmp/install_voice_stack.sh >> /tmp/voice-install.log 2>&1
    echo 'Script téléchargé, chmod +x...' >> /tmp/voice-install.log
    chmod +x /tmp/install_voice_stack.sh
    echo 'Début exécution du script d installation...' >> /tmp/voice-install.log
  "
  
  log "⚙️ Exécution de l'installation de la stack (cela peut prendre 10-15 minutes)..."
  log "📋 Suivi des logs en temps réel..."
  
  # Exécuter l'installation en arrière-plan et suivre les logs
  pct exec "${CT_VMID}" -- bash -c "
    /tmp/install_voice_stack.sh --install-ollama --dir /opt/voice-stack >> /tmp/voice-install.log 2>&1 &
    INSTALL_PID=\$!
    echo \"PID d'installation: \$INSTALL_PID\" >> /tmp/voice-install.log
    
    # Attendre la fin de l'installation
    while kill -0 \$INSTALL_PID 2>/dev/null; do
      echo \"Installation en cours... \$(date)\" >> /tmp/voice-install.log
      sleep 30
    done
    
    echo '=== INSTALLATION TERMINÉE - $(date) ===' >> /tmp/voice-install.log
  " &
  
  # Suivre les logs pendant l'installation
  local install_time=0
  local max_install_time=1200  # 20 minutes max
  
  while [[ $install_time -lt $max_install_time ]]; do
    sleep 30
    install_time=$((install_time + 30))
    
    # Lire la dernière ligne du log
    local last_log
    last_log=$(pct exec "${CT_VMID}" -- tail -1 /tmp/voice-install.log 2>/dev/null || echo "")
    
    if [[ -n "$last_log" ]]; then
      log "📋 CT:${CT_VMID} - $last_log"
    fi
    
    # Vérifier si l'installation est terminée
    if pct exec "${CT_VMID}" -- grep -q "INSTALLATION TERMINÉE" /tmp/voice-install.log 2>/dev/null; then
      success "✅ Installation de la stack terminée avec succès!"
      return
    fi
    
    # Afficher le progrès
    if [[ $((install_time % 120)) -eq 0 ]]; then
      log "⏱️ Installation en cours... ${install_time}s/${max_install_time}s"
    fi
  done
  
  warning "⚠️ Timeout d'installation atteint. Vérifiez les logs manuellement."
}

test_services() {
  log "🔍 Test des services installés..."
  
  # Obtenir l'IP du conteneur
  local ct_ip
  ct_ip=$(pct exec "${CT_VMID}" -- hostname -I | awk '{print $1}' || echo "")
  
  if [[ -n "$ct_ip" ]]; then
    log "🌐 IP du conteneur: $ct_ip"
    
    # Test XTTS
    if pct exec "${CT_VMID}" -- curl -s http://localhost:8000/ >/dev/null 2>&1; then
      success "✅ XTTS fonctionne (port 8000)"
    else
      warning "❌ XTTS ne répond pas sur le port 8000"
    fi
    
    # Test Ollama
    if pct exec "${CT_VMID}" -- curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
      success "✅ Ollama fonctionne (port 11434)"
    else
      warning "❌ Ollama ne répond pas sur le port 11434"
    fi
    
    # Afficher les logs
    log "📋 Dernières lignes du log d'installation:"
    pct exec "${CT_VMID}" -- tail -5 /tmp/voice-install.log 2>/dev/null || log "Logs non disponibles"
  else
    warning "❌ Impossible de détecter l'IP du conteneur"
  fi
}

show_final_summary() {
  local ct_ip
  ct_ip=$(pct exec "${CT_VMID}" -- hostname -I | awk '{print $1}' || echo "IP non détectée")
  
  cat <<EOF

${COLOR_BOLD}=== Conteneur LXC voice-clone créé et configuré ===${COLOR_RESET}

${COLOR_BLUE}Informations conteneur:${COLOR_RESET}
- Nom: ${CT_NAME}
- VMID: ${CT_VMID}
- RAM: ${CT_MEMORY}MB ($(( CT_MEMORY / 1024 ))GB)
- CPU: ${CT_CORES} cœurs
- Disque: ${CT_DISK_SIZE}GB
- IP: ${ct_ip}

${COLOR_BLUE}Accès conteneur:${COLOR_RESET}
- Console: pct enter ${CT_VMID}
- SSH: ssh root@${ct_ip}
- Mot de passe: ${CT_PASSWORD}

${COLOR_BLUE}Services installés:${COLOR_RESET}
- XTTS v2: http://${ct_ip}:8000/
- Ollama: http://${ct_ip}:11434/

${COLOR_BOLD}Test rapide:${COLOR_RESET}
curl http://${ct_ip}:8000/

${COLOR_BOLD}Commandes utiles:${COLOR_RESET}
- Entrer dans le conteneur: pct enter ${CT_VMID}
- Logs installation: pct exec ${CT_VMID} -- cat /tmp/voice-install.log
- Arrêter: pct stop ${CT_VMID}
- Démarrer: pct start ${CT_VMID}

${COLOR_GREEN}Installation automatique terminée !${COLOR_RESET}

EOF
}

main() {
  printf '%s=== Installation automatique conteneur LXC voice-clone ===%s\n\n' "${COLOR_BOLD}" "${COLOR_RESET}"
  
  check_prerequisites
  find_next_vmid
  download_ubuntu_template
  create_lxc_container
  start_and_install
  test_services
  show_final_summary
}

main "$@"
