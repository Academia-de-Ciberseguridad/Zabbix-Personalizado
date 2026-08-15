#!/usr/bin/env bash
# ===========================================================================
#  setup-host.sh — Instala los REQUISITOS del laboratorio en la máquina del
#  alumno: Docker Engine + Docker Compose v2 + utilidades base (make, openssl,
#  python3, git). El laboratorio en sí no necesita nada más: todo lo demás
#  (secretos, PSK, TLS, BD, hosts, Grafana) lo genera 'make full'.
#
#  Cubre Linux de la familia Debian (Kali / Debian / Ubuntu). Para otras
#  distribuciones, macOS y Windows imprime la vía recomendada y termina.
#
#  Uso:   bash scripts/setup-host.sh          (pregunta antes de tocar nada)
#         bash scripts/setup-host.sh --yes     (sin preguntar, para aulas)
# ===========================================================================
set -euo pipefail
YES=0; [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ] && YES=1
log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[setup]\033[0m %s\n' "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

confirm() {  # $1 = mensaje
  [ "$YES" -eq 1 ] && return 0
  printf '\033[1;33m[setup]\033[0m %s [s/N] ' "$1"; read -r r
  case "$r" in s|S|y|Y) return 0;; *) return 1;; esac
}

# --- Sistemas no-Linux: guiar a Docker Desktop -----------------------------
OS="$(uname -s)"
if [ "$OS" != "Linux" ]; then
  case "$OS" in
    Darwin) cat <<'EOF'
  Estás en macOS. El laboratorio funciona sobre Docker Desktop:
    1. Descarga Docker Desktop para Mac: https://www.docker.com/products/docker-desktop/
       (o con Homebrew:  brew install --cask docker )
    2. Ábrelo una vez para que arranque el motor.
    3. Compose v2 y las utilidades ya vienen incluidas.
    4. Vuelve a la carpeta del lab y ejecuta:  make full
EOF
    ;;
    *) cat <<'EOF'
  Estás en Windows (o un sistema no soportado por este script).
    1. Instala Docker Desktop con backend WSL2:
       https://www.docker.com/products/docker-desktop/
    2. Instala una distro Linux en WSL2 (p.ej. Kali o Ubuntu) desde la Store.
    3. Clona el lab DENTRO de WSL2 (no en C:\) y, en esa terminal Linux,
       ejecuta:  make full
EOF
    ;;
  esac
  exit 0
fi

# --- Detectar distribución -------------------------------------------------
. /etc/os-release 2>/dev/null || die "No encuentro /etc/os-release; instala Docker manualmente."
DISTRO_ID="${ID:-}"; LIKE="${ID_LIKE:-}"
log "Distribución detectada: ${PRETTY_NAME:-$DISTRO_ID}"

is_debian_family() { case " $DISTRO_ID $LIKE " in *" debian "*|*" ubuntu "*|*kali*) return 0;; esac; [ "$DISTRO_ID" = debian ] || [ "$DISTRO_ID" = ubuntu ] || [ "$DISTRO_ID" = kali ]; }

if ! is_debian_family; then
  cat <<EOF
  Tu distribución (${PRETTY_NAME:-$DISTRO_ID}) no es de la familia Debian.
  Instala Docker con el método oficial de tu distro y vuelve a ejecutar:
    - Fedora/RHEL:  https://docs.docker.com/engine/install/fedora/
    - Arch:         sudo pacman -S docker docker-compose
    - Genérico:     curl -fsSL https://get.docker.com | sh
  Después:  sudo systemctl enable --now docker && sudo usermod -aG docker \$USER
  Y añade las utilidades: make openssl python3 git
EOF
  exit 0
fi

# --- sudo ------------------------------------------------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then have sudo || die "Necesito privilegios: instala 'sudo' o ejecuta como root."; SUDO="sudo"; fi

echo ""
log "Se van a instalar: Docker Engine, Docker Compose v2, make, openssl, python3, git."
confirm "¿Continuar con la instalación (apt)?" || die "Cancelado por el usuario."

export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -y

# Kali: los paquetes de la propia distro traen Docker + Compose v2 ('docker-compose' = plugin v2).
if [ "$DISTRO_ID" = kali ] || case " $LIKE " in *kali*) true;; *) false;; esac; then
  log "Ruta Kali: instalando docker.io + docker-compose desde el repositorio de Kali."
  $SUDO apt-get install -y docker.io docker-compose make openssl python3 git
else
  # Debian / Ubuntu: repositorio oficial de Docker (Engine + plugin de Compose v2).
  log "Ruta Debian/Ubuntu: configurando el repositorio oficial de Docker."
  $SUDO apt-get install -y ca-certificates curl gnupg make openssl python3 git
  $SUDO install -m 0755 -d /etc/apt/keyrings
  REPO="$DISTRO_ID"; case " $LIKE " in *ubuntu*) REPO=ubuntu;; *debian*) REPO=debian;; esac
  [ "$DISTRO_ID" = ubuntu ] && REPO=ubuntu; [ "$DISTRO_ID" = debian ] && REPO=debian
  CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-stable}}"
  if [ ! -s /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL "https://download.docker.com/linux/$REPO/gpg" | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$REPO $CODENAME stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# --- Arrancar el demonio y permitir uso sin sudo ---------------------------
if have systemctl; then
  $SUDO systemctl enable --now docker 2>/dev/null || warn "No pude habilitar docker con systemd; arráncalo manualmente."
fi
if ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  log "Añadiendo '$USER' al grupo 'docker' (para usar docker sin sudo)."
  $SUDO usermod -aG docker "$USER" || warn "No pude modificar el grupo; usarás docker con sudo."
  NEED_RELOGIN=1
fi

# --- Verificación final ----------------------------------------------------
echo ""
log "Instalación terminada. Verificando con preflight..."
echo ""
bash "$BASE/scripts/preflight.sh" || true

if [ "${NEED_RELOGIN:-0}" = 1 ]; then
  echo ""
  warn "IMPORTANTE: cierra sesión y vuelve a entrar (o ejecuta 'newgrp docker')"
  warn "para poder usar Docker sin sudo. Después:  make full"
fi
