#!/usr/bin/env bash
# create_voice_clone_vm_auto.sh
#
# Script de création et installation automatique complète d'une VM Proxmox 
# pour le clonage de voix avec XTTS v2 et Ollama
#
# Ce script fait TOUT automatiquement :
# 1. Crée la VM Proxmox
# 2. Démarre la VM
# 3. Installe Ubuntu automatiquement (cloud-init)
# 4. Installe la stack de clonage de voix
#
# Utilisation :
#   ./create_voice_clone_vm_auto.sh [options]

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
VM_NAME="voice-clone-auto"
VM_MEMORY=8192      # 8GB RAM
VM_CORES=4          # 4 cœurs CPU
VM_DISK_SIZE=50     # 50GB disque
VM_STORAGE="local-lvm"
VM_BRIDGE="vmbr0"
VM_VMID=""
VM_USERNAME="voiceuser"
VM_PASSWORD="VoiceClone2024!"
SSH_KEY=""

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
Usage : create_voice_clone_vm_auto.sh [options]

Ce script crée et configure automatiquement une VM Proxmox complète pour 
le clonage de voix avec installation Ubuntu automatique et stack XTTS.

Options disponibles :
  --vmid <id>           ID de la VM (par défaut: auto-détection)
  --storage <name>      Stockage pour la VM (par défaut: local-lvm)
  --memory <MB>         RAM en MB (par défaut: 8192 = 8GB)
  --cores <num>         Nombre de cœurs CPU (par défaut: 4)
  --disk <GB>           Taille du disque en GB (par défaut: 50)
  --bridge <name>       Bridge réseau (par défaut: vmbr0)
  --username <user>     Nom d'utilisateur Ubuntu (par défaut: voiceuser)
  --password <pass>     Mot de passe Ubuntu (par défaut: VoiceClone2024!)
  --ssh-key <key>       Clé SSH publique (optionnel)
  -h, --help            Affiche cette aide

Exemples :
  # Installation complète automatique
  ./create_voice_clone_vm_auto.sh

  # Avec paramètres personnalisés
  ./create_voice_clone_vm_auto.sh --memory 16384 --cores 8 --username admin

  # Avec clé SSH
  ./create_voice_clone_vm_auto.sh --ssh-key "$(cat ~/.ssh/id_rsa.pub)"
EOF
}

# Parse des arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)
      VM_VMID="$2"; shift 2 ;;
    --storage)
      VM_STORAGE="$2"; shift 2 ;;
    --memory)
      VM_MEMORY="$2"; shift 2 ;;
    --cores)
      VM_CORES="$2"; shift 2 ;;
    --disk)
      VM_DISK_SIZE="$2"; shift 2 ;;
    --bridge)
      VM_BRIDGE="$2"; shift 2 ;;
    --username)
      VM_USERNAME="$2"; shift 2 ;;
    --password)
      VM_PASSWORD="$2"; shift 2 ;;
    --ssh-key)
      SSH_KEY="$2"; shift 2 ;;
    -h|--help)
      print_usage; exit 0 ;;
    *)
      error "Option inconnue : $1"; print_usage >&2; exit 1 ;;
  esac
done

check_prerequisites() {
  log "Vérification des prérequis..."
  
  if ! command -v qm >/dev/null 2>&1; then
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
  if [[ -n "${VM_VMID}" ]]; then
    log "Utilisation du VMID spécifié: ${VM_VMID}"
    if qm status "${VM_VMID}" >/dev/null 2>&1 || pct status "${VM_VMID}" >/dev/null 2>&1; then
      error "Le VMID ${VM_VMID} est déjà utilisé."
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
  
  for ((i=200; i<=299; i++)); do
    if ! echo "${existing_vmids}" | grep -q "^${i}$"; then
      VM_VMID="$i"
      break
    fi
  done
  
  if [[ -z "${VM_VMID}" ]]; then
    error "Impossible de trouver un VMID libre entre 200 et 299."
    exit 1
  fi
  
  success "VMID libre trouvé: ${VM_VMID}"
}

download_ubuntu_cloud_image() {
  log "Téléchargement de l'image cloud Ubuntu 24.04..."
  
  local cloud_image="/var/lib/vz/template/iso/ubuntu-24.04-server-cloudimg-amd64.img"
  
  if [[ ! -f "${cloud_image}" ]]; then
    log "Téléchargement de l'image cloud Ubuntu..."
    wget -O "${cloud_image}" \
      "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
  else
    log "Image cloud Ubuntu déjà présente"
  fi
  
  success "Image cloud Ubuntu prête: ${cloud_image}"
}

create_cloud_init_config() {
  log "Création de la configuration cloud-init..."
  
  local cloud_init_file="/tmp/cloud-init-${VM_VMID}.yml"
  
  cat > "${cloud_init_file}" <<EOF
#cloud-config
hostname: voice-clone
manage_etc_hosts: true

users:
  - name: ${VM_USERNAME}
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    passwd: $(echo "${VM_PASSWORD}" | openssl passwd -6 -stdin)
EOF

  if [[ -n "${SSH_KEY}" ]]; then
    cat >> "${cloud_init_file}" <<EOF
    ssh_authorized_keys:
      - ${SSH_KEY}
EOF
  fi

  cat >> "${cloud_init_file}" <<EOF

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - git
  - htop
  - nano
  - openssh-server
  - qemu-guest-agent
runcmd:
  - systemctl enable ssh
  - systemctl start ssh
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - echo "=== VM DÉMARRÉE - Attente stabilisation système ===" > /tmp/voice-install.log
  - echo "$(date): Démarrage des services système..." >> /tmp/voice-install.log
  - sleep 60
  - echo "$(date): Système stabilisé, début installation stack de clonage de voix" >> /tmp/voice-install.log
  - echo "$(date): Téléchargement du script d'installation..." >> /tmp/voice-install.log
  - wget -O /tmp/install_voice_stack.sh "https://raw.githubusercontent.com/Sdavid66/clone_voice/main/install_voice_stack.sh" >> /tmp/voice-install.log 2>&1 || echo "ERREUR: Échec téléchargement script" >> /tmp/voice-install.log
  - chmod +x /tmp/install_voice_stack.sh
  - echo "$(date): === DÉBUT INSTALLATION STACK VOICE CLONING ===" >> /tmp/voice-install.log
  - /tmp/install_voice_stack.sh --install-ollama --dir /opt/voice-stack >> /tmp/voice-install.log 2>&1 || echo "ERREUR: Échec installation stack" >> /tmp/voice-install.log
  - echo "$(date): === DÉMARRAGE DES SERVICES ===" >> /tmp/voice-install.log
  - cd /opt/voice-stack/xtts && docker compose up -d >> /tmp/voice-install.log 2>&1 || echo "ERREUR: Échec démarrage Docker XTTS" >> /tmp/voice-install.log
  - systemctl start ollama >> /tmp/voice-install.log 2>&1 || echo "ERREUR: Échec démarrage Ollama" >> /tmp/voice-install.log
  - echo "$(date): === VÉRIFICATION DES SERVICES ===" >> /tmp/voice-install.log
  - sleep 10
  - curl -s http://localhost:8000/ >> /tmp/voice-install.log 2>&1 && echo "✅ XTTS fonctionne (port 8000)" >> /tmp/voice-install.log || echo "❌ XTTS ne répond pas" >> /tmp/voice-install.log
  - curl -s http://localhost:11434/api/tags >> /tmp/voice-install.log 2>&1 && echo "✅ Ollama fonctionne (port 11434)" >> /tmp/voice-install.log || echo "❌ Ollama ne répond pas" >> /tmp/voice-install.log
  - echo "$(date): === INSTALLATION TERMINÉE ===" >> /tmp/voice-install.log

final_message: |
  VM voice-clone prête !
  Utilisateur: ${VM_USERNAME}
  Mot de passe: ${VM_PASSWORD}
  
  Services installés:
  - XTTS v2 (port 8000)
  - Ollama (port 11434)
  
  Vérifiez les logs: /tmp/voice-install.log
EOF

  success "Configuration cloud-init créée: ${cloud_init_file}"
}

create_vm_with_cloud_init() {
  log "Création de la VM avec cloud-init..."
  
  local cloud_image="/var/lib/vz/template/iso/ubuntu-24.04-server-cloudimg-amd64.img"
  local cloud_init_file="/tmp/cloud-init-${VM_VMID}.yml"
  
  # Créer la VM
  qm create "${VM_VMID}" \
    --name "${VM_NAME}" \
    --memory "${VM_MEMORY}" \
    --cores "${VM_CORES}" \
    --sockets 1 \
    --cpu host \
    --ostype l26 \
    --net0 "virtio,bridge=${VM_BRIDGE}" \
    --serial0 socket \
    --vga serial0 \
    --agent enabled=1
  
  # Importer l'image cloud comme disque
  qm importdisk "${VM_VMID}" "${cloud_image}" "${VM_STORAGE}"
  
  # Configurer le disque
  qm set "${VM_VMID}" --scsi0 "${VM_STORAGE}:vm-${VM_VMID}-disk-0"
  qm set "${VM_VMID}" --boot order=scsi0
  qm set "${VM_VMID}" --scsi1 "${VM_STORAGE}:cloudinit"
  
  # Redimensionner le disque
  qm resize "${VM_VMID}" scsi0 "${VM_DISK_SIZE}G"
  
  # Copier le fichier cloud-init
  mkdir -p /var/lib/vz/snippets/
  cp "${cloud_init_file}" "/var/lib/vz/snippets/cloud-init-${VM_VMID}.yml"
  
  # Configurer cloud-init
  qm set "${VM_VMID}" --cicustom "user=local:snippets/cloud-init-${VM_VMID}.yml"
  
  # Configurer les paramètres cloud-init directement
  qm set "${VM_VMID}" --ciuser "${VM_USERNAME}"
  qm set "${VM_VMID}" --cipassword "${VM_PASSWORD}"
  qm set "${VM_VMID}" --ipconfig0 "ip=dhcp"
  
  success "VM créée avec cloud-init (ID: ${VM_VMID})"
}

start_and_wait_vm() {
  log "Démarrage de la VM et attente de l'installation..."
  
  qm start "${VM_VMID}"
  
  log "VM démarrée. Installation Ubuntu et stack de clonage en cours..."
  log "Suivi en temps réel de l'installation (peut prendre 15-20 minutes)..."
  
  # Attendre que la VM soit prête avec suivi des logs
  local max_wait=1200  # 20 minutes
  local wait_time=0
  local vm_ready=false
  local last_log_line=""
  
  while [[ $wait_time -lt $max_wait ]]; do
    # Méthode 1: Test agent QEMU
    if qm agent "${VM_VMID}" ping >/dev/null 2>&1; then
      success "VM prête - Agent QEMU actif"
      vm_ready=true
      break
    fi
    
    # Méthode 2: Obtenir IP via différentes méthodes
    local vm_ip=""
    
    # Essayer via agent QEMU
    vm_ip=$(qm agent "${VM_VMID}" network-get-interfaces 2>/dev/null | grep -oP '(?<="ip-address":")\d+\.\d+\.\d+\.\d+' | head -1 || echo "")
    
    # Si pas d'IP via agent, essayer via ARP
    if [[ -z "$vm_ip" ]]; then
      local vm_mac
      vm_mac=$(qm config "${VM_VMID}" | grep -oP 'net0:.*,macaddr=([^,]+)' | cut -d'=' -f2 || echo "")
      if [[ -n "$vm_mac" ]]; then
        vm_ip=$(arp -a | grep -i "$vm_mac" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || echo "")
      fi
    fi
    
    # Si pas d'IP via ARP, scanner le réseau local
    if [[ -z "$vm_ip" ]]; then
      local network_range
      network_range=$(ip route | grep -oP '192\.168\.\d+\.0/24' | head -1 || echo "")
      if [[ -n "$network_range" ]]; then
        vm_ip=$(nmap -sn "$network_range" 2>/dev/null | grep -B2 "voice-clone" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || echo "")
      fi
    fi
    
    if [[ -n "$vm_ip" ]]; then
      log "🌐 IP VM détectée: $vm_ip"
      
      # Tester SSH
      if nc -z "$vm_ip" 22 2>/dev/null; then
        log "🔐 SSH accessible sur $vm_ip"
        
        # Lire les logs d'installation
        local current_log
        current_log=$(timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${VM_USERNAME}@${vm_ip}" "tail -1 /tmp/voice-install.log 2>/dev/null" 2>/dev/null || echo "")
        
        if [[ -n "$current_log" && "$current_log" != "$last_log_line" ]]; then
          log "📋 VM: $current_log"
          last_log_line="$current_log"
        fi
        
        # Vérifier si l'installation est terminée
        if echo "$current_log" | grep -q "INSTALLATION TERMINÉE"; then
          success "Installation terminée avec succès !"
          vm_ready=true
          break
        fi
        
        # Vérifier les services directement
        if timeout 5 ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${VM_USERNAME}@${vm_ip}" "curl -s http://localhost:8000/ >/dev/null 2>&1" 2>/dev/null; then
          success "XTTS détecté actif sur port 8000 !"
          vm_ready=true
          break
        fi
      fi
    fi
    
    # Affichage du progrès
    if [[ $((wait_time % 60)) -eq 0 ]]; then
      log "⏱️  Attente... ${wait_time}s/${max_wait}s (IP: ${vm_ip:-"non détectée"}) - Installation en cours"
    else
      printf "."
    fi
    
    sleep 30
    wait_time=$((wait_time + 30))
  done
  
  if [[ "$vm_ready" == "false" ]]; then
    warning "Timeout atteint après 20 minutes."
    warning "L'installation peut encore être en cours. Vérifiez manuellement :"
    warning "ssh ${VM_USERNAME}@${vm_ip} 'tail -f /tmp/voice-install.log'"
  fi
}

show_final_summary() {
  local vm_ip=""
  
  # Essayer plusieurs méthodes pour obtenir l'IP
  vm_ip=$(qm agent "${VM_VMID}" network-get-interfaces 2>/dev/null | grep -oP '(?<="ip-address":")\d+\.\d+\.\d+\.\d+' | head -1 || echo "")
  
  if [[ -z "$vm_ip" ]]; then
    local vm_mac
    vm_mac=$(qm config "${VM_VMID}" | grep -oP 'net0:.*,macaddr=([^,]+)' | cut -d'=' -f2 || echo "")
    if [[ -n "$vm_mac" ]]; then
      vm_ip=$(arp -a | grep -i "$vm_mac" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || echo "")
    fi
  fi
  
  if [[ -z "$vm_ip" ]]; then
    vm_ip="IP non détectée - Utilisez: qm terminal ${VM_VMID}"
  fi
  
  cat <<EOF

${COLOR_BOLD}=== VM voice-clone créée et configurée automatiquement ===${COLOR_RESET}

${COLOR_BLUE}Informations VM:${COLOR_RESET}
- Nom: ${VM_NAME}
- VMID: ${VM_VMID}
- RAM: ${VM_MEMORY}MB ($(( VM_MEMORY / 1024 ))GB)
- CPU: ${VM_CORES} cœurs
- Disque: ${VM_DISK_SIZE}GB
- IP: ${vm_ip}

${COLOR_BLUE}Accès VM:${COLOR_RESET}
- Utilisateur: ${VM_USERNAME}
- Mot de passe: ${VM_PASSWORD}
- SSH: ssh ${VM_USERNAME}@${vm_ip}

${COLOR_BLUE}Services installés:${COLOR_RESET}
- XTTS v2: http://${vm_ip}:8000/
- Ollama: http://${vm_ip}:11434/

${COLOR_BOLD}Test rapide:${COLOR_RESET}
curl http://${vm_ip}:8000/

${COLOR_BOLD}Commandes utiles:${COLOR_RESET}
- Console VM: qm terminal ${VM_VMID}
- Logs installation: ssh ${VM_USERNAME}@${vm_ip} "cat /tmp/voice-install.log"
- Arrêter VM: qm stop ${VM_VMID}
- Démarrer VM: qm start ${VM_VMID}

${COLOR_GREEN}Installation automatique terminée !${COLOR_RESET}

EOF
}

post_install_diagnostic() {
  log "🔍 Diagnostic post-installation..."
  
  # Obtenir l'IP de la VM
  local vm_ip=""
  vm_ip=$(qm agent "${VM_VMID}" network-get-interfaces 2>/dev/null | grep -oP '(?<="ip-address":")\d+\.\d+\.\d+\.\d+' | head -1 || echo "")
  
  if [[ -z "$vm_ip" ]]; then
    local vm_mac
    vm_mac=$(qm config "${VM_VMID}" | grep -oP 'net0:.*,macaddr=([^,]+)' | cut -d'=' -f2 || echo "")
    if [[ -n "$vm_mac" ]]; then
      vm_ip=$(arp -a | grep -i "$vm_mac" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || echo "")
    fi
  fi
  
  if [[ -n "$vm_ip" ]]; then
    log "🌐 IP VM: $vm_ip"
    
    # Test des services
    if timeout 5 ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${VM_USERNAME}@${vm_ip}" "curl -s http://localhost:8000/ >/dev/null 2>&1" 2>/dev/null; then
      success "✅ XTTS fonctionne (port 8000)"
    else
      warning "❌ XTTS ne répond pas sur le port 8000"
    fi
    
    if timeout 5 ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${VM_USERNAME}@${vm_ip}" "curl -s http://localhost:11434/api/tags >/dev/null 2>&1" 2>/dev/null; then
      success "✅ Ollama fonctionne (port 11434)"
    else
      warning "❌ Ollama ne répond pas sur le port 11434"
    fi
    
    # Afficher les dernières lignes du log
    log "📋 Dernières lignes du log d'installation:"
    timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${VM_USERNAME}@${vm_ip}" "tail -5 /tmp/voice-install.log 2>/dev/null" 2>/dev/null || log "Impossible de lire les logs"
  else
    warning "❌ Impossible de détecter l'IP de la VM"
    log "💡 Utilisez: qm terminal ${VM_VMID} pour accéder à la console"
  fi
}

main() {
  printf '%s=== Installation automatique VM voice-clone ===%s\n\n' "${COLOR_BOLD}" "${COLOR_RESET}"
  
  check_prerequisites
  find_next_vmid
  download_ubuntu_cloud_image
  create_cloud_init_config
  create_vm_with_cloud_init
  start_and_wait_vm
  post_install_diagnostic
  show_final_summary
}

main "$@"
