#!/usr/bin/env bash
# install_voice_stack.sh
#
# Script d'installation "one-shot" pour préparer un environnement local de clonage de voix
# basé sur XTTS v2 (CPU uniquement) + Docker sur Ubuntu 22.04/24.04.
#
# Utilisation recommandée :
#   curl -fsSL https://raw.githubusercontent.com/sdavid66/clone_voice/main/install_voice_stack.sh \
#     | sudo bash -s -- [options]
#   (ou télécharger le script puis l'exécuter manuellement)
#
# Variables/Options utiles :
#   --install-ollama / INSTALL_OLLAMA=true  # installe Ollama et télécharge le modèle "mistral"
#   --no-start / START_CONTAINERS=false     # génère les fichiers sans lancer immédiatement XTTS
#   --dir <chemin> / VOICE_STACK_DIR=...    # change le dossier cible (par défaut ~/voice-stack)

set -euo pipefail

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

CURRENT_STEP=0
STEP_SKIPPED=0
TOTAL_STEPS=0

if [[ "${EUID}" -ne 0 ]]; then
  echo "${COLOR_RED}[ERREUR] Ce script doit être exécuté avec les droits administrateur (sudo/root).${COLOR_RESET}" >&2
  exit 1
fi

# Détermine l'utilisateur principal auquel rattacher Docker et les fichiers générés.
TARGET_USER=${SUDO_USER:-root}
if [[ "${TARGET_USER}" == "root" ]]; then
  TARGET_HOME="/root"
else
  TARGET_HOME=$(eval echo "~${TARGET_USER}")
fi

print_usage() {
  cat <<'EOF'
Usage : install_voice_stack.sh [options]

Options disponibles :
  --dir <chemin>        Change le répertoire de travail (équivalent à VOICE_STACK_DIR).
  --install-ollama     Force l'installation d'Ollama (équivalent à INSTALL_OLLAMA=true).
  --no-ollama          Désactive explicitement l'installation d'Ollama.
  --no-start           Génère les fichiers sans démarrer docker compose (START_CONTAINERS=false).
  --start              Force le démarrage des conteneurs (START_CONTAINERS=true).
  -h, --help           Affiche ce message d'aide et quitte.

Les options en ligne de commande ont priorité sur les variables d'environnement
éventuellement définies (VOICE_STACK_DIR, START_CONTAINERS, INSTALL_OLLAMA).
EOF
}

VOICE_STACK_DIR_DEFAULT="${TARGET_HOME}/voice-stack"
START_CONTAINERS_DEFAULT="true"
INSTALL_OLLAMA_DEFAULT="false"

VOICE_STACK_DIR_ENV=${VOICE_STACK_DIR:-}
START_CONTAINERS_ENV=${START_CONTAINERS:-}
INSTALL_OLLAMA_ENV=${INSTALL_OLLAMA:-}

VOICE_STACK_DIR_CLI=""
START_CONTAINERS_CLI=""
INSTALL_OLLAMA_CLI=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      if [[ $# -lt 2 ]]; then
        echo "${COLOR_RED}[ERREUR] L'option --dir nécessite un argument (chemin).${COLOR_RESET}" >&2
        exit 1
      fi
      VOICE_STACK_DIR_CLI="$2"
      shift 2
      continue
      ;;
    --install-ollama)
      INSTALL_OLLAMA_CLI="true"
      ;;
    --no-ollama|--skip-ollama)
      INSTALL_OLLAMA_CLI="false"
      ;;
    --no-start)
      START_CONTAINERS_CLI="false"
      ;;
    --start)
      START_CONTAINERS_CLI="true"
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "${COLOR_RED}[ERREUR] Option inconnue : $1${COLOR_RESET}" >&2
      print_usage >&2
      exit 1
      ;;
  esac
  shift
done

VOICE_STACK_DIR=${VOICE_STACK_DIR_CLI:-${VOICE_STACK_DIR_ENV:-${VOICE_STACK_DIR_DEFAULT}}}
START_CONTAINERS=${START_CONTAINERS_CLI:-${START_CONTAINERS_ENV:-${START_CONTAINERS_DEFAULT}}}
INSTALL_OLLAMA=${INSTALL_OLLAMA_CLI:-${INSTALL_OLLAMA_ENV:-${INSTALL_OLLAMA_DEFAULT}}}

if [[ $# -gt 0 ]]; then
  echo "${COLOR_RED}[ERREUR] Arguments inattendus : $*${COLOR_RESET}" >&2
  print_usage >&2
  exit 1
fi

XTTS_DIR="${VOICE_STACK_DIR}/xtts"

log() {
  printf '      %s[%s]%s %s\n' "${COLOR_DIM}" "$(date '+%H:%M:%S')" "${COLOR_RESET}" "$*"
}

run_step() {
  local description="$1"
  local func="$2"

  CURRENT_STEP=$((CURRENT_STEP + 1))
  STEP_SKIPPED=0

  printf '\n%s[%d/%d]%s %s%s%s\n' \
    "${COLOR_BOLD}" "${CURRENT_STEP}" "${TOTAL_STEPS}" "${COLOR_RESET}" "${COLOR_BLUE}" "${description}" "${COLOR_RESET}"

  if "$func"; then
    if [[ "${STEP_SKIPPED}" -eq 1 ]]; then
      printf '   ↳ %s⚠ Étape ignorée%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
    else
      printf '   ↳ %s✔ Succès%s\n' "${COLOR_GREEN}" "${COLOR_RESET}"
    fi
  else
    printf '   ↳ %s✖ Échec%s\n' "${COLOR_RED}" "${COLOR_RESET}"
    exit 1
  fi
}

ensure_packages() {
  log "Mise à jour de la liste des paquets APT"
  apt-get update
  log "Installation des dépendances système"
  apt-get install -y \
    ca-certificates \
    curl \
    ffmpeg \
    git \
    gnupg \
    lsb-release \
    python3-pip \
    software-properties-common \
    apt-transport-https
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker est déjà installé sur ce système."
    STEP_SKIPPED=1
    return 0
  fi

  log "Installation du dépôt Docker officiel..."
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Détection automatique de la distribution (Ubuntu/Debian)
  . /etc/os-release
  
  # Utilise le bon codename selon la distribution
  if [[ "${ID}" == "ubuntu" ]]; then
    DISTRO_CODENAME="${UBUNTU_CODENAME}"
    DISTRO_NAME="ubuntu"
  elif [[ "${ID}" == "debian" ]]; then
    DISTRO_CODENAME="${VERSION_CODENAME}"
    DISTRO_NAME="debian"
  else
    log "Distribution non supportée: ${ID}. Tentative avec ubuntu..."
    DISTRO_CODENAME="jammy"
    DISTRO_NAME="ubuntu"
  fi

  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_NAME} \
${DISTRO_CODENAME} stable" \
    | tee /etc/apt/sources.list.d/docker.list >/dev/null

  log "Installation de Docker Engine + plugin Compose..."
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
}

configure_docker_group() {
  if [[ "${TARGET_USER}" == "root" ]]; then
    log "Utilisateur root détecté : aucune modification de groupe nécessaire."
    STEP_SKIPPED=1
    return 0
  fi
  if id -nG "${TARGET_USER}" | grep -qw docker; then
    log "L'utilisateur ${TARGET_USER} appartient déjà au groupe docker."
    STEP_SKIPPED=1
    return 0
  fi

  log "Ajout de l'utilisateur ${TARGET_USER} au groupe docker..."
  usermod -aG docker "${TARGET_USER}"
  DOCKER_GROUP_UPDATED=1
}

install_ollama() {
  if [[ "${INSTALL_OLLAMA}" != "true" ]]; then
    log "INSTALL_OLLAMA=false : Ollama ne sera pas installé."
    STEP_SKIPPED=1
    return 0
  fi

  if command -v ollama >/dev/null 2>&1; then
    log "Ollama est déjà installé. Vérification des modèles disponibles."
  else
    log "Installation d'Ollama (mode CPU)..."
    # L'installeur gère automatiquement la détection GPU/CPU. Aucune interaction requise.
    curl -fsSL https://ollama.com/install.sh | sh
    
    # Démarrage du service Ollama
    systemctl enable --now ollama 2>/dev/null || true
  fi

  # Attendre que le service soit prêt
  local max_attempts=30
  local attempt=0
  while [[ $attempt -lt $max_attempts ]]; do
    if ollama list >/dev/null 2>&1; then
      break
    fi
    log "Attente du démarrage d'Ollama... ($((attempt + 1))/$max_attempts)"
    sleep 2
    attempt=$((attempt + 1))
  done

  if [[ $attempt -eq $max_attempts ]]; then
    log "AVERTISSEMENT: Ollama ne répond pas, le téléchargement du modèle sera ignoré"
    return 0
  fi

  if ! ollama list | grep -qw mistral; then
    log "Téléchargement du modèle 'mistral' pour Ollama..."
    ollama pull mistral
  fi
}

write_xtts_files() {
  log "Préparation de l'arborescence XTTS dans ${XTTS_DIR}"
  mkdir -p "${XTTS_DIR}"

  cat <<'DOCKERFILE' >"${XTTS_DIR}/Dockerfile"
FROM python:3.11-slim
ENV DEBIAN_FRONTEND=noninteractive

# Installer les dépendances système et nettoyer immédiatement
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg git build-essential pkg-config \
    && pip install --no-cache-dir --upgrade pip setuptools wheel \
    && pip install --no-cache-dir \
        fastapi uvicorn python-multipart \
        pydub soundfile numpy \
    && pip install --no-cache-dir TTS \
    && apt-get remove -y build-essential pkg-config \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && pip cache purge \
    && find /usr/local -name "*.pyc" -delete \
    && find /usr/local -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

WORKDIR /app
COPY app.py /app/app.py
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
DOCKERFILE

  cat <<'APP' >"${XTTS_DIR}/app.py"
from fastapi import FastAPI, UploadFile, File, Form, Response
import tempfile
import os
from TTS.api import TTS

app = FastAPI(title="XTTSv2 Voice Cloning API", version="1.0")

_tts = None


def get_tts():
    global _tts
    if _tts is None:
        _tts = TTS(model_name="tts_models/multilingual/multi-dataset/xtts_v2")
    return _tts


@app.post("/speak", summary="Synthétise un texte en clonant une voix")
async def speak(text: str = Form(...), speaker_wav: UploadFile = File(None), language: str = Form("fr")):
    tts = get_tts()

    speaker_path = None
    if speaker_wav is not None:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as tmp:
            tmp.write(await speaker_wav.read())
            speaker_path = tmp.name

    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as out_tmp:
        out_path = out_tmp.name

    tts.tts_to_file(
        text=text,
        speaker_wav=speaker_path,
        file_path=out_path,
        language=language,
    )

    with open(out_path, "rb") as f:
        audio_bytes = f.read()

    os.unlink(out_path)
    if speaker_path:
        os.unlink(speaker_path)

    return Response(content=audio_bytes, media_type="audio/wav")


@app.get("/", summary="Statut du service")
async def root():
    return {"status": "ok", "model": "xtts_v2"}
APP

  cat <<'COMPOSE' >"${XTTS_DIR}/docker-compose.yml"
services:
  xtts:
    build: .
    ports:
      - "8000:8000"
    volumes:
      - "./voices:/app/voices"
      - "./outputs:/app/outputs"
    environment:
      - PYTHONUNBUFFERED=1
    restart: always
    depends_on: []
COMPOSE

  log "Ajustement des permissions sur ${VOICE_STACK_DIR} pour ${TARGET_USER}"
  chown -R "${TARGET_USER}:${TARGET_USER}" "${VOICE_STACK_DIR}"
}

build_and_launch_xtts() {
  if [[ "${START_CONTAINERS}" != "true" ]]; then
    log "START_CONTAINERS=false : génération des fichiers uniquement."
    STEP_SKIPPED=1
    return 0
  fi

  # Vérification que Docker Compose est disponible
  if ! command -v docker >/dev/null 2>&1; then
    log "ERREUR: Docker n'est pas disponible"
    return 1
  fi

  # Test de la commande docker compose
  if ! docker compose version >/dev/null 2>&1; then
    log "ERREUR: Docker Compose plugin n'est pas disponible"
    return 1
  fi

  log "Construction de l'image XTTS (CPU)..."
  cd "${XTTS_DIR}" || return 1
  docker compose build

  log "Lancement du service XTTS (FastAPI) en arrière-plan..."
  docker compose up -d
}

post_summary() {
  log "Installation terminée."
  cat <<EOF

Résumé :
  - Fichiers générés : ${XTTS_DIR}/{Dockerfile,app.py,docker-compose.yml}
  - Service XTTS (CPU) exposé sur http://localhost:8000/
  - Volume de cache Docker : xtts-cache (modèles conservés entre redémarrages)

Tests rapides :
  curl http://localhost:8000/
  curl -X POST http://localhost:8000/speak \\
    -F "text=Bonjour, ceci est un test." \\
    -F "speaker_wav=@votre_sample.wav" \\
    --output sortie.wav

Conseils :
  * Utilisez des échantillons WAV courts (3-15 s) et propres pour un meilleur clonage.
  * Si Ollama est installé, l'API locale tourne sur http://localhost:11434/ (modèle mistral).
EOF

  if [[ "${DOCKER_GROUP_UPDATED:-0}" -eq 1 ]]; then
    cat <<EOF

⚠️  Un ajout au groupe docker a été effectué pour l'utilisateur ${TARGET_USER}.
   Déconnectez-vous / reconnectez-vous (ou exécutez 'newgrp docker') pour en tenir compte.
EOF
  fi
}

print_header() {
  printf '%s=== Installation automatisée de la stack XTTS (CPU) ===%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
  log "Utilisateur cible : ${TARGET_USER}"
  log "Répertoire principal : ${VOICE_STACK_DIR}"
  log "Répertoire XTTS : ${XTTS_DIR}"
  log "Démarrage automatique des conteneurs : ${START_CONTAINERS}"
  log "Installation d'Ollama : ${INSTALL_OLLAMA}"
  printf '\n'
}

check_prerequisites() {
  log "Vérification des prérequis système..."
  
  # Vérifier qu'on n'est pas sur un hôte Proxmox
  if [[ -f /etc/pve/.version ]] || command -v qm >/dev/null 2>&1; then
    echo "${COLOR_RED}[ERREUR CRITIQUE] Ce script ne doit PAS être exécuté sur l'hôte Proxmox !${COLOR_RESET}" >&2
    echo "${COLOR_RED}Vous devez d'abord créer une VM, puis exécuter ce script DANS la VM.${COLOR_RESET}" >&2
    echo "" >&2
    echo "${COLOR_YELLOW}Étapes correctes :${COLOR_RESET}" >&2
    echo "${COLOR_YELLOW}1. Créer une VM avec : curl -fsSL https://raw.githubusercontent.com/Sdavid66/clone_voice/main/create_voice_clone_vm.sh | sudo bash${COLOR_RESET}" >&2
    echo "${COLOR_YELLOW}2. Installer Ubuntu dans la VM${COLOR_RESET}" >&2
    echo "${COLOR_YELLOW}3. Exécuter ce script DANS la VM Ubuntu${COLOR_RESET}" >&2
    echo "" >&2
    exit 1
  fi
  
  # Vérification de la distribution
  if [[ ! -f /etc/os-release ]]; then
    log "ERREUR: Impossible de détecter la distribution système"
    return 1
  fi
  
  . /etc/os-release
  if [[ "${ID}" != "ubuntu" && "${ID}" != "debian" ]]; then
    log "AVERTISSEMENT: Distribution ${ID} non officiellement supportée"
    log "Le script tentera de continuer avec les paramètres Ubuntu"
  fi
  
  # Vérification de l'architecture
  local arch
  arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
  if [[ "${arch}" != "amd64" && "${arch}" != "x86_64" ]]; then
    log "AVERTISSEMENT: Architecture ${arch} non testée"
  fi
  
  # Vérification de l'espace disque (minimum 2GB)
  local available_space
  available_space=$(df / | awk 'NR==2 {print $4}')
  if [[ "${available_space}" -lt 2097152 ]]; then
    log "AVERTISSEMENT: Espace disque faible (< 2GB disponible)"
  fi
  
  # Vérification de la connectivité internet
  if ! curl -s --connect-timeout 5 https://google.com >/dev/null; then
    log "ERREUR: Pas de connectivité internet détectée"
    return 1
  fi
  
  log "Prérequis système validés"
}

STEPS=(
  "Vérification des prérequis système:::check_prerequisites"
  "Installation des dépendances système:::ensure_packages"
  "Installation ou vérification de Docker:::install_docker"
  "Configuration du groupe Docker:::configure_docker_group"
  "Installation optionnelle d'Ollama:::install_ollama"
  "Préparation des fichiers XTTS:::write_xtts_files"
  "Construction et lancement des conteneurs XTTS:::build_and_launch_xtts"
  "Résumé de fin d'installation:::post_summary"
)

TOTAL_STEPS=${#STEPS[@]}

main() {
  print_header

  local entry description func
  for entry in "${STEPS[@]}"; do
    description="${entry%:::*}"
    func="${entry#*:::}"
    run_step "${description}" "${func}"
  done
}

main "$@"
