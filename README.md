# clone_voice

Déploiement automatisé d'une stack de clonage de voix basée sur XTTS v2 (CPU) pour un environnement Ubuntu/Proxmox.
Le script `install_voice_stack.sh` prépare Docker, génère les fichiers nécessaires (Dockerfile, `docker-compose.yml`, API FastAPI) et peut lancer directement le service.
Un suivi de progression en couleur est intégré pour visualiser chaque étape (vert = succès, rouge = échec, jaune = étape ignorée).

## Installation express depuis GitHub

> ⚠️ L'exécution doit se faire avec les privilèges `root` ou via `sudo`.

```bash
curl -fsSL "https://raw.githubusercontent.com/sdavid66/clone_voice/main/install_voice_stack.sh?nocache=$(date +%s)" \
  | sudo bash -s --
```

Le script détecte automatiquement :
- l'utilisateur principal à rattacher au groupe `docker` ;
- le dossier de travail (`~/voice-stack` par défaut) ;
- l'activation optionnelle d'Ollama et le démarrage automatique du conteneur XTTS.

### Personnalisation via variables d'environnement

Le script accepte à la fois des variables d'environnement **et** des options en ligne de commande.
Les options ont priorité sur les variables (pratique pour l'exécution en "one-liner").

| Option CLI | Variable associée | Description |
| --- | --- | --- |
| `--dir <chemin>` | `VOICE_STACK_DIR` | Répertoire d'installation (contient `xtts/`). |
| `--no-start` / `--start` | `START_CONTAINERS` | `--no-start` pour générer les fichiers uniquement, `--start` pour forcer le lancement. |
| `--install-ollama` / `--no-ollama` | `INSTALL_OLLAMA` | Active/désactive l'installation d'Ollama (mode CPU) et le téléchargement du modèle `mistral`. |

Exemple : ne pas démarrer le service immédiatement et installer Ollama dans `/opt/voice-stack` :

```bash
curl -fsSL "https://raw.githubusercontent.com/sdavid66/clone_voice/main/create_voice_clone_lxc.sh?nocache=$(date +%s)" | bash -s --

```

### Exécution locale (script déjà téléchargé)

```bash
chmod +x install_voice_stack.sh
sudo ./install_voice_stack.sh
```

## Service déployé

- API FastAPI `XTTSv2 Voice Cloning` exposée sur `http://localhost:8000/`
- Volume Docker `xtts-cache` (persistance des modèles téléchargés)
- Image locale `local/xtts:v1`

Tests rapides :

```bash
curl http://localhost:8000/
curl -X POST http://localhost:8000/speak \
  -F "text=Bonjour, ceci est un test." \
  -F "speaker_wav=@/chemin/vers/votre_sample.wav" \
  --output sortie.wav
```

## Dépannage & journalisation

Chaque étape affiche un statut coloré :
- ✅ vert : étape réussie ;
- ⚠️ jaune : étape ignorée (par exemple Docker déjà présent ou installation Ollama désactivée) ;
- ❌ rouge : échec et arrêt du script.

Les messages détaillés apparaissent sous chaque étape avec un horodatage.

## Ressources complémentaires

- Le script `install_voice_stack.sh` peut être adapté pour d'autres environnements (Debian 12, etc.) en ajustant les dépendances.
