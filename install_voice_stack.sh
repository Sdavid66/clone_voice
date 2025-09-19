#!/usr/bin/env bash
# install_voice_stack.sh
#
# Script d'installation "one-shot" pour préparer un environnement local de clonage de voix
# basé sur XTTS v2 (CPU uniquement) + Docker sur Ubuntu 22.04/24.04.
#
# Utilisation recommandée :
#   curl -fsSL https://exemple/install_voice_stack.sh -o install_voice_stack.sh
#   sudo bash install_voice_stack.sh
#
# Variables optionnelles (à exporter avant exécution) :
#   INSTALL_OLLAMA=true     # installe Ollama et télécharge un modèle léger (mistral) pour LLM local
#   START_CONTAINERS=false  # génère les fichiers mais ne lance pas le conteneur XTTS immédiatement
#   VOICE_STACK_DIR=/opt/voice-stack  # change le dossier cible (par défaut ~/voice-stack)

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

VOICE_STACK_DIR=${VOICE_STACK_DIR:-"${TARGET_HOME}/voice-stack"}
XTTS_DIR="${VOICE_STACK_DIR}/xtts"

START_CONTAINERS=${START_CONTAINERS:-true}
INSTALL_OLLAMA=${INSTALL_OLLAMA:-false}

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
    python3-pip
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

  . /etc/os-release
  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
${UBUNTU_CODENAME} stable" \
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
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg git && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir --upgrade pip
RUN pip install --no-cache-dir TTS fastapi uvicorn pydub soundfile numpy
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
    image: local/xtts:v1
    ports:
      - "8000:8000"
    volumes:
      - xtts-cache:/root/.local/share/tts
    environment:
      - PYTHONUNBUFFERED=1
volumes:
  xtts-cache:
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

  log "Construction de l'image XTTS (CPU)..."
  docker compose -f "${XTTS_DIR}/docker-compose.yml" build

  log "Lancement du service XTTS (FastAPI) en arrière-plan..."
  docker compose -f "${XTTS_DIR}/docker-compose.yml" up -d
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

STEPS=(
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
    IFS=':::' read -r description func <<<"${entry}"
    run_step "${description}" "${func}"
  done
}

main "$@"
