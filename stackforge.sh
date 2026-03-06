#!/bin/sh
# ============================================================
#  ███████╗████████╗ █████╗  ██████╗██╗  ██╗███████╗ ██████╗ ██████╗  ██████╗ ███████╗
#  ██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝
#  ███████╗   ██║   ███████║██║     █████╔╝ █████╗  ██║   ██║██████╔╝██║  ███╗█████╗
#  ╚════██║   ██║   ██╔══██║██║     ██╔═██╗ ██╔══╝  ██║   ██║██╔══██╗██║   ██║██╔══╝
#  ███████║   ██║   ██║  ██║╚██████╗██║  ██╗██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗
#  ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝
#
#  stackforge v0.4.0 — guided homelab infrastructure bootstrapper
#
#  Runs on:
#    ┌─────────────────────┬────────────────────────────────────────────┐
#    │ Environment         │ Cluster Engine                             │
#    ├─────────────────────┼────────────────────────────────────────────┤
#    │ Bare-metal Linux    │ k3s (native binary, systemd)               │
#    │ Docker Desktop Mac  │ k3d (k3s-in-Docker, no root needed)        │
#    │ Docker Desktop Win  │ k3d via WSL2 (same as Mac)                 │
#    │ Linux VM            │ k3s (detected as bare-metal)               │
#    └─────────────────────┴────────────────────────────────────────────┘
#
#  KUBECONFIG GUARANTEE:
#    stackforge NEVER reads, writes, or merges ~/.kube/config
#    All cluster access uses: ~/.stackforge/kubeconfig
#    Existing clusters are completely unaffected.
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/ry-ops/stackforge/main/stackforge.sh | sh
#
#  Subcommands:
#    --worker           Join this machine to an existing stackforge bare-metal cluster
#    --destroy          Tear down the stackforge cluster (safe, isolated)
#    --kubeconfig       Print path to the stackforge kubeconfig file
#    --reset-passwords  Generate new passwords for all services
# ============================================================

set -eu

# ─── Globals ────────────────────────────────────────────────
STACKFORGE_VERSION="0.4.0"
STACKFORGE_DIR="${HOME}/.stackforge"
STACKFORGE_KUBECONFIG="${STACKFORGE_DIR}/kubeconfig"  # NEVER ~/.kube/config
STATE_FILE="${STACKFORGE_DIR}/state.env"
LOG_FILE="${STACKFORGE_DIR}/stackforge.log"
K3S_VERSION="v1.29.4+k3s1"
K3D_CLUSTER_NAME="stackforge"
REPO_RAW="https://raw.githubusercontent.com/ry-ops/stackforge/main"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "${HOME}/.stackforge")"
REPO_LOCAL="${SCRIPT_DIR}"

# Port assignments
PORT_DASHBOARD=30080
PORT_PORTAINER_HTTP=30777
PORT_PORTAINER_HTTPS=30779
PORT_TRAEFIK_HTTP=32080
PORT_TRAEFIK_HTTPS=32443
PORT_GRAFANA=32000
PORT_PROMETHEUS=32001
PORT_UPTIME_KUMA=32100
PORT_TRAEFIK_DASH=32090

# Runtime state — populated by detect_environment()
ENV_MODE=""        # "baremetal" | "docker-desktop" | "wsl2"
OS_FAMILY=""       # "debian" | "rhel" | "fedora" | "suse" | "arch" | "alpine" | "darwin"
OS_PRETTY=""
ARCH=""
ARCH_LABEL=""
NODE_IP=""
ACCESS_HOST=""     # What the browser navigates to (127.0.0.1 vs LAN IP)
DOCKER_INSTALLED=false
K3S_INSTALLED=false
K3D_INSTALLED=false
HELM_INSTALLED=false
INSTALLED_SERVICES=""

# ─── Colors ─────────────────────────────────────────────────
RESET='\033[0m';    BOLD='\033[1m';     DIM='\033[2m'
RED='\033[0;31m';   GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m';  WHITE='\033[0;37m'
BGREEN='\033[1;32m'; BCYAN='\033[1;36m'; BYELLOW='\033[1;33m'; BRED='\033[1;31m'

# ─── Logging ─────────────────────────────────────────────────
mkdir -p "${STACKFORGE_DIR}"

# Set up logging via a FIFO so output goes to both stdout and log file
_LOG_FIFO="${STACKFORGE_DIR}/.log_fifo.$$"
_cleanup_fifo() { rm -f "${_LOG_FIFO}"; }
trap _cleanup_fifo EXIT
mkfifo "${_LOG_FIFO}"
tee -a "${LOG_FILE}" < "${_LOG_FIFO}" &
exec > "${_LOG_FIFO}" 2>&1

log()     { printf "${DIM}%s${RESET} ${WHITE}%s${RESET}\n" "$(date '+%H:%M:%S')" "$*"; }
info()    { printf "${CYAN}  →${RESET} %s\n" "$*"; }
ok()      { printf "${BGREEN}  ✔${RESET} %s\n" "$*"; }
warn()    { printf "${BYELLOW}  ⚠${RESET} %s\n" "$*"; }
err()     { printf "${BRED}  ✖${RESET} %s\n" "$*" >&2; }
die()     { err "$*"; exit 1; }
section() { printf "\n${BCYAN}━━━ ${BOLD}%s${RESET}${BCYAN} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n\n" "$*"; }

banner() {
  printf "${BCYAN}"
  cat << 'BANNER'
  ███████╗████████╗ █████╗  ██████╗██╗  ██╗███████╗ ██████╗ ██████╗  ██████╗ ███████╗
  ██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝
  ███████╗   ██║   ███████║██║     █████╔╝ █████╗  ██║   ██║██████╔╝██║  ███╗█████╗
  ╚════██║   ██║   ██╔══██║██║     ██╔═██╗ ██╔══╝  ██║   ██║██╔══██╗██║   ██║██╔══╝
  ███████║   ██║   ██║  ██║╚██████╗██║  ██╗██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗
  ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝
BANNER
  printf "${RESET}\n"
  printf "  ${DIM}v%s — guided homelab infrastructure bootstrapper${RESET}\n" "${STACKFORGE_VERSION}"
  printf "  ${DIM}github.com/ry-ops/stackforge${RESET}\n\n"
}

# ─── kubectl / helm wrappers ─────────────────────────────────
# These ALWAYS use the isolated stackforge kubeconfig.
# They cannot accidentally touch any other cluster.
kc() { KUBECONFIG="${STACKFORGE_KUBECONFIG}" kubectl "$@"; }
hm() { KUBECONFIG="${STACKFORGE_KUBECONFIG}" helm "$@"; }

# ─── Prompt Helpers ──────────────────────────────────────────
prompt_yn() {
  local q="$1" default="${2:-y}"
  local display
  if [ "$default" = "y" ]; then
    display="${BGREEN}Y${RESET}${DIM}/n${RESET}"
  else
    display="${DIM}y/${RESET}${RED}N${RESET}"
  fi
  printf "  ${CYAN}?${RESET} %s [%b] " "$q" "$display"
  read -r reply
  reply="${reply:-$default}"
  reply=$(printf '%s' "$reply" | tr 'A-Z' 'a-z')
  [ "$reply" = "y" ]
}

prompt_input() {
  local q="$1" default="${2:-}"
  if [ -n "$default" ]; then
    printf "  ${CYAN}?${RESET} %s ${DIM}[%s]${RESET} " "$q" "$default"
  else
    printf "  ${CYAN}?${RESET} %s " "$q"
  fi
  read -r reply
  printf '%s' "${reply:-$default}"
}

# ─── Password Generation ─────────────────────────────────────
generate_password() {
  head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16
}

# ─── Credentials Secret ─────────────────────────────────────
create_credentials_secret() {
  section "Setting Up Credentials"

  local grafana_user="admin"
  local grafana_pass
  local portainer_pass

  # Reuse existing passwords if state.env already has them
  if [ -f "${STATE_FILE}" ] && grep -q "GRAFANA_ADMIN_PASSWORD=" "${STATE_FILE}" 2>/dev/null; then
    grafana_pass=$(grep "^GRAFANA_ADMIN_PASSWORD=" "${STATE_FILE}" | cut -d'=' -f2)
    portainer_pass=$(grep "^PORTAINER_ADMIN_PASSWORD=" "${STATE_FILE}" | cut -d'=' -f2)
    info "Reusing existing credentials from ${STATE_FILE}"
  else
    grafana_pass=$(generate_password)
    portainer_pass=$(generate_password)
    info "Generated new random credentials"
  fi

  # Create secret in stackforge namespace
  kc create namespace stackforge --dry-run=client -o yaml | kc apply -f - >/dev/null 2>&1
  kc create secret generic stackforge-credentials \
    --from-literal="grafana-admin-user=${grafana_user}" \
    --from-literal="grafana-admin-password=${grafana_pass}" \
    --from-literal="portainer-admin-password=${portainer_pass}" \
    --namespace stackforge \
    --dry-run=client -o yaml | kc apply -f -

  # Create same secret in monitoring namespace (Grafana's existingSecret requires same-namespace)
  kc create namespace monitoring --dry-run=client -o yaml | kc apply -f - >/dev/null 2>&1
  kc create secret generic stackforge-credentials \
    --from-literal="grafana-admin-user=${grafana_user}" \
    --from-literal="grafana-admin-password=${grafana_pass}" \
    --from-literal="portainer-admin-password=${portainer_pass}" \
    --namespace monitoring \
    --dry-run=client -o yaml | kc apply -f -

  # Persist to state.env for recovery
  {
    grep -v "^GRAFANA_ADMIN_USER=\|^GRAFANA_ADMIN_PASSWORD=\|^PORTAINER_ADMIN_PASSWORD=" "${STATE_FILE}" 2>/dev/null || true
    echo "GRAFANA_ADMIN_USER=${grafana_user}"
    echo "GRAFANA_ADMIN_PASSWORD=${grafana_pass}"
    echo "PORTAINER_ADMIN_PASSWORD=${portainer_pass}"
  } > "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "${STATE_FILE}"
  chmod 600 "${STATE_FILE}"

  # Export for use in install functions
  GRAFANA_USER="${grafana_user}"
  GRAFANA_PASS="${grafana_pass}"
  PORTAINER_PASS="${portainer_pass}"

  ok "Credentials secret created in stackforge and monitoring namespaces"
  ok "Credentials saved to ${STATE_FILE}"
}

# ─── Reset Passwords ─────────────────────────────────────────
reset_passwords() {
  section "Resetting All Passwords"

  local grafana_pass
  local portainer_pass
  grafana_pass=$(generate_password)
  portainer_pass=$(generate_password)

  info "Generated new passwords"

  # Patch secrets in both namespaces
  for ns in stackforge monitoring; do
    kc create secret generic stackforge-credentials \
      --from-literal="grafana-admin-user=admin" \
      --from-literal="grafana-admin-password=${grafana_pass}" \
      --from-literal="portainer-admin-password=${portainer_pass}" \
      --namespace "${ns}" \
      --dry-run=client -o yaml | kc apply -f -
  done
  ok "Kubernetes secrets updated"

  # Sync Grafana password via API
  local grafana_url="http://${ACCESS_HOST}:${PORT_GRAFANA}"
  local old_grafana_pass
  old_grafana_pass=$(grep "^GRAFANA_ADMIN_PASSWORD=" "${STATE_FILE}" 2>/dev/null | cut -d'=' -f2 || echo "stackforge")

  info "Syncing Grafana password..."
  if curl -fsSk -X PUT "${grafana_url}/api/admin/users/1/password" \
    -H "Content-Type: application/json" \
    -u "admin:${old_grafana_pass}" \
    -d "{\"password\":\"${grafana_pass}\"}" >/dev/null 2>&1; then
    ok "Grafana password updated"
  else
    warn "Could not sync Grafana password via API (service may be down)"
  fi

  # Sync Portainer password via API
  local portainer_url="https://${ACCESS_HOST}:${PORT_PORTAINER_HTTPS}"
  local old_portainer_pass
  old_portainer_pass=$(grep "^PORTAINER_ADMIN_PASSWORD=" "${STATE_FILE}" 2>/dev/null | cut -d'=' -f2 || echo "stackforge")

  info "Syncing Portainer password..."
  local jwt
  jwt=$(curl -fsSk -X POST "${portainer_url}/api/auth" \
    -H "Content-Type: application/json" \
    -d "{\"Username\":\"admin\",\"Password\":\"${old_portainer_pass}\"}" 2>/dev/null | tr -d '"{}' | sed 's/jwt://')

  if [ -n "$jwt" ] && [ "$jwt" != "" ]; then
    if curl -fsSk -X PUT "${portainer_url}/api/users/1/passwd" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${jwt}" \
      -d "{\"password\":\"${portainer_pass}\"}" >/dev/null 2>&1; then
      ok "Portainer password updated"
    else
      warn "Could not sync Portainer password via API"
    fi
  else
    warn "Could not authenticate with Portainer (service may be down)"
  fi

  # Update state.env
  {
    grep -v "^GRAFANA_ADMIN_USER=\|^GRAFANA_ADMIN_PASSWORD=\|^PORTAINER_ADMIN_PASSWORD=" "${STATE_FILE}" 2>/dev/null || true
    echo "GRAFANA_ADMIN_USER=admin"
    echo "GRAFANA_ADMIN_PASSWORD=${grafana_pass}"
    echo "PORTAINER_ADMIN_PASSWORD=${portainer_pass}"
  } > "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "${STATE_FILE}"
  chmod 600 "${STATE_FILE}"

  echo ""
  printf "  ${BOLD}New Credentials:${RESET}\n"
  printf "    ${BGREEN}Grafana${RESET}    admin / ${BCYAN}%s${RESET}\n" "${grafana_pass}"
  printf "    ${BGREEN}Portainer${RESET}  admin / ${BCYAN}%s${RESET}\n" "${portainer_pass}"
  echo ""
  printf "  ${DIM}Saved to: %s${RESET}\n" "${STATE_FILE}"
  ok "Password reset complete"
}

# ─── Service list helpers (replaces bash arrays) ─────────────
svc_add() {
  if [ -z "$INSTALLED_SERVICES" ]; then
    INSTALLED_SERVICES="$1"
  else
    INSTALLED_SERVICES="${INSTALLED_SERVICES}
$1"
  fi
}

svc_count() {
  if [ -z "$INSTALLED_SERVICES" ]; then
    echo 0
  else
    printf '%s\n' "$INSTALLED_SERVICES" | wc -l | tr -d ' '
  fi
}

# ─── Environment Detection ───────────────────────────────────
detect_environment() {
  section "Detecting Environment"

  ARCH=$(uname -m)
  case "${ARCH}" in
    x86_64)        ARCH_LABEL="amd64" ;;
    aarch64|arm64) ARCH_LABEL="arm64" ;;
    armv7l)        ARCH_LABEL="arm"   ;;
    *)             die "Unsupported CPU architecture: ${ARCH}" ;;
  esac

  local kernel
  kernel=$(uname -s)

  # ── macOS ──────────────────────────────────────────────────
  if [ "$kernel" = "Darwin" ]; then
    ENV_MODE="docker-desktop"
    OS_FAMILY="darwin"
    OS_PRETTY="macOS $(sw_vers -productVersion 2>/dev/null || true)"
    ACCESS_HOST="127.0.0.1"
    NODE_IP="127.0.0.1"
    ok "Environment: ${OS_PRETTY} → Docker Desktop mode (k3d)"
    _require_docker_desktop
    return
  fi

  # ── Linux: check WSL2 first ────────────────────────────────
  if [ -f /proc/version ] && grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
    ENV_MODE="wsl2"
    ACCESS_HOST="127.0.0.1"
    NODE_IP="127.0.0.1"
    _detect_linux_distro
    ok "Environment: WSL2 on Windows → Docker Desktop mode (k3d)"
    warn "No systemd required. k3s runs entirely inside Docker containers."
    _require_docker_desktop
    return
  fi

  # ── Bare-metal / VM Linux ──────────────────────────────────
  ENV_MODE="baremetal"
  _detect_linux_distro
  NODE_IP=$(hostname -I | awk '{print $1}')
  ACCESS_HOST="${NODE_IP}"
  ok "Environment: Bare-metal / VM Linux → k3s native (${NODE_IP})"
}

_detect_linux_distro() {
  [ -f /etc/os-release ] || die "/etc/os-release missing — cannot identify Linux distro."
  # shellcheck source=/dev/null
  . /etc/os-release
  local id="${ID:-}" like="${ID_LIKE:-}"
  OS_PRETTY="${PRETTY_NAME:-Linux}"
  case "${id}" in
    ubuntu|debian|raspbian|linuxmint|pop)  OS_FAMILY="debian" ;;
    rhel|centos|rocky|almalinux|ol)        OS_FAMILY="rhel"   ;;
    fedora)                                 OS_FAMILY="fedora" ;;
    opensuse*|sles)                         OS_FAMILY="suse"   ;;
    arch|manjaro|endeavouros)               OS_FAMILY="arch"   ;;
    alpine)                                 OS_FAMILY="alpine" ;;
    *)
      echo "${like}" | grep -q "debian"       && OS_FAMILY="debian" && return
      echo "${like}" | grep -qE "rhel|fedora" && OS_FAMILY="rhel"   && return
      die "Unsupported distro: ${OS_PRETTY}. Open an issue: github.com/ry-ops/stackforge"
      ;;
  esac
  ok "Distro: ${OS_PRETTY} (${ARCH})"
}

_require_docker_desktop() {
  if ! command -v docker >/dev/null 2>&1; then
    echo ""
    err "Docker Desktop not found. Please install it first:"
    printf "  ${DIM}macOS:   https://docs.docker.com/desktop/install/mac-install/${RESET}\n"
    printf "  ${DIM}Windows: https://docs.docker.com/desktop/install/windows-install/${RESET}\n"
    echo ""
    die "Docker Desktop is required for this environment."
  fi
  if ! docker info >/dev/null 2>&1; then
    die "Docker is installed but not running. Start Docker Desktop first, then re-run stackforge."
  fi
  DOCKER_INSTALLED=true
  ok "Docker Desktop: running ✓"
}

# ─── Package Manager (bare-metal only) ───────────────────────
pkg_update() {
  [ "${ENV_MODE}" = "baremetal" ] || return 0
  info "Updating package lists..."
  case "${OS_FAMILY}" in
    debian)        sudo apt-get update -qq ;;
    rhel|fedora)   sudo dnf check-update -q 2>/dev/null || true ;;
    suse)          sudo zypper refresh -q ;;
    arch)          sudo pacman -Sy --quiet ;;
    alpine)        sudo apk update --quiet ;;
  esac
}

pkg_install() {
  [ "${ENV_MODE}" = "baremetal" ] || return 0
  info "Installing packages: $*"
  case "${OS_FAMILY}" in
    debian)        sudo apt-get install -y -qq "$@" ;;
    rhel)          sudo dnf install -y -q "$@" 2>/dev/null || sudo yum install -y -q "$@" ;;
    fedora)        sudo dnf install -y -q "$@" ;;
    suse)          sudo zypper install -y -q "$@" ;;
    arch)          sudo pacman -S --noconfirm --quiet "$@" ;;
    alpine)        sudo apk add --quiet "$@" ;;
  esac
}

# ─── Prerequisites ────────────────────────────────────────────
check_prerequisites() {
  section "Checking Prerequisites"

  if [ "${ENV_MODE}" = "baremetal" ]; then
    [ "$(id -u)" -ne 0 ] || die "Don't run as root. stackforge uses sudo internally."
    command -v sudo >/dev/null 2>&1 || die "sudo is required but not installed."
    if ! command -v curl >/dev/null 2>&1; then
      pkg_update
      pkg_install curl
    fi
  fi

  command -v k3s  >/dev/null 2>&1 && K3S_INSTALLED=true  && ok "k3s:  already installed"
  command -v k3d  >/dev/null 2>&1 && K3D_INSTALLED=true  && ok "k3d:  already installed"
  command -v helm >/dev/null 2>&1 && HELM_INSTALLED=true && ok "Helm: already installed"

  # Warn but NEVER touch existing kubeconfig
  if [ -f "${HOME}/.kube/config" ]; then
    local n
    n=$(kubectl config get-contexts --no-headers 2>/dev/null | wc -l || echo "?")
    warn "Found existing ~/.kube/config (${n} context(s)) — stackforge will NOT touch it."
    warn "All stackforge access uses: ${STACKFORGE_KUBECONFIG}"
  fi
}

# ─── Tooling ──────────────────────────────────────────────────
install_kubectl() {
  command -v kubectl >/dev/null 2>&1 && { ok "kubectl: already installed"; return; }
  info "Installing kubectl..."
  local ver
  ver=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  case "${OS_FAMILY}" in
    darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install kubectl >/dev/null 2>&1
      else
        curl -fsSLo /usr/local/bin/kubectl \
          "https://dl.k8s.io/release/${ver}/bin/darwin/${ARCH_LABEL}/kubectl"
        chmod +x /usr/local/bin/kubectl
      fi
      ;;
    *)
      curl -fsSLo /tmp/kubectl \
        "https://dl.k8s.io/release/${ver}/bin/linux/${ARCH_LABEL}/kubectl"
      sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
      rm /tmp/kubectl
      ;;
  esac
  ok "kubectl installed."
}

install_helm() {
  [ "${HELM_INSTALLED}" = "true" ] && { ok "Helm: already installed"; return; }
  info "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | sh -s -- --no-sudo
  HELM_INSTALLED=true
  ok "Helm installed."
}

install_k3d() {
  [ "${K3D_INSTALLED}" = "true" ] && { ok "k3d: already installed"; return; }
  info "Installing k3d (k3s-in-Docker)..."
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | sh
  K3D_INSTALLED=true
  ok "k3d installed."
}

# ─── Docker Engine (bare-metal only) ─────────────────────────
install_docker_baremetal() {
  section "Installing Docker Engine"
  [ "${DOCKER_INSTALLED}" = "true" ] && { info "Docker already installed."; return; }

  # shellcheck source=/dev/null
  [ -f /etc/os-release ] && . /etc/os-release

  case "${OS_FAMILY}" in
    debian)
      pkg_update
      pkg_install ca-certificates gnupg lsb-release
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/${ID} $(lsb_release -cs) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      pkg_update
      pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    rhel|fedora)
      sudo dnf config-manager --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
      pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    suse)
      sudo zypper addrepo https://download.docker.com/linux/sles/docker-ce.repo 2>/dev/null || true
      pkg_install docker-ce docker-ce-cli containerd.io
      ;;
    arch)  pkg_install docker docker-compose ;;
    alpine) pkg_install docker docker-cli-compose ;;
  esac

  sudo systemctl enable --now docker
  sudo usermod -aG docker "${USER}"
  DOCKER_INSTALLED=true
  ok "Docker Engine installed and started."
  warn "Log out and back in (or run 'newgrp docker') for group membership to take effect."
}

# ─── Cluster Bootstrap: Docker Desktop / WSL2 (k3d) ──────────
bootstrap_k3d() {
  section "Bootstrapping k3d Cluster"
  printf "  ${DIM}Mode: k3s running inside Docker Desktop containers${RESET}\n"
  printf "  ${DIM}1 control-plane + 2 worker nodes. No root. No systemd. Fully isolated.${RESET}\n\n"

  # Check if cluster already exists
  if k3d cluster list 2>/dev/null | grep -q "^${K3D_CLUSTER_NAME}"; then
    warn "k3d cluster '${K3D_CLUSTER_NAME}' already exists."
    if prompt_yn "Delete and recreate it?" "n"; then
      k3d cluster delete "${K3D_CLUSTER_NAME}"
    else
      info "Using existing cluster."
      k3d kubeconfig get "${K3D_CLUSTER_NAME}" > "${STACKFORGE_KUBECONFIG}"
      chmod 600 "${STACKFORGE_KUBECONFIG}"
      return
    fi
  fi

  info "Creating k3d cluster '${K3D_CLUSTER_NAME}' (1 control-plane + 2 agents)..."

  k3d cluster create "${K3D_CLUSTER_NAME}" \
    --agents 2 \
    --k3s-arg "--disable=traefik@server:0" \
    --k3s-arg "--disable=servicelb@server:0" \
    --port "${PORT_DASHBOARD}:${PORT_DASHBOARD}@loadbalancer" \
    --port "${PORT_PORTAINER_HTTPS}:${PORT_PORTAINER_HTTPS}@loadbalancer" \
    --port "${PORT_TRAEFIK_HTTP}:${PORT_TRAEFIK_HTTP}@loadbalancer" \
    --port "${PORT_TRAEFIK_HTTPS}:${PORT_TRAEFIK_HTTPS}@loadbalancer" \
    --port "${PORT_GRAFANA}:${PORT_GRAFANA}@loadbalancer" \
    --port "${PORT_PROMETHEUS}:${PORT_PROMETHEUS}@loadbalancer" \
    --port "${PORT_UPTIME_KUMA}:${PORT_UPTIME_KUMA}@loadbalancer" \
    --port "${PORT_TRAEFIK_DASH}:${PORT_TRAEFIK_DASH}@loadbalancer" \
    --wait

  # Write isolated kubeconfig — never merge, never touch ~/.kube/config
  k3d kubeconfig get "${K3D_CLUSTER_NAME}" > "${STACKFORGE_KUBECONFIG}"
  chmod 600 "${STACKFORGE_KUBECONFIG}"

  ok "Cluster created."
  ok "Kubeconfig: ${STACKFORGE_KUBECONFIG}"
  ok "~/.kube/config was NOT modified."

  # Wait for nodes
  info "Waiting for all nodes to be Ready..."
  local t=0
  until kc get nodes 2>/dev/null | grep -v "NotReady" | grep -qc "Ready" | grep -q "[1-9]" \
      || kc get nodes 2>/dev/null | grep -c "Ready" | grep -q "[1-9]"; do
    sleep 4; t=$((t+4))
    [ $t -ge 120 ] && die "Timed out waiting for cluster."
    printf "  ${DIM}waiting... %ds${RESET}\r" "$t"
  done
  echo ""
  ok "Cluster ready:"
  kc get nodes | sed 's/^/    /'
}

# ─── Cluster Bootstrap: Bare-metal (k3s) ─────────────────────
bootstrap_k3s_master() {
  section "Bootstrapping k3s Control Plane"

  if [ "${K3S_INSTALLED}" = "true" ]; then
    info "k3s already installed — configuring kubeconfig."
  else
    info "Installing k3s ${K3S_VERSION}..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" \
      K3S_KUBECONFIG_MODE="644" \
      sh -s - server \
        --disable traefik \
        --disable servicelb \
        --write-kubeconfig-mode 644
    sudo systemctl enable --now k3s
    K3S_INSTALLED=true
    ok "k3s installed and started."
  fi

  # Copy k3s kubeconfig to stackforge's isolated location
  # Replace 127.0.0.1 with actual node IP so workers and remote clients can use it
  sudo cp /etc/rancher/k3s/k3s.yaml "${STACKFORGE_KUBECONFIG}"
  sudo chown "${USER}:${USER}" "${STACKFORGE_KUBECONFIG}"
  chmod 600 "${STACKFORGE_KUBECONFIG}"
  sed -i "s|127.0.0.1|${NODE_IP}|g" "${STACKFORGE_KUBECONFIG}"

  ok "Kubeconfig: ${STACKFORGE_KUBECONFIG}"
  ok "~/.kube/config was NOT modified."

  # Wait for node ready
  info "Waiting for control plane..."
  local t=0
  until kc get nodes 2>/dev/null | grep -q "Ready"; do
    sleep 5; t=$((t+5))
    [ $t -ge 120 ] && die "Timed out waiting for k3s."
    printf "  ${DIM}waiting... %ds${RESET}\r" "$t"
  done
  echo ""
  ok "Control plane Ready."

  # Save state for workers
  local token
  token=$(sudo cat /var/lib/rancher/k3s/server/node-token)
  {
    echo "K3S_TOKEN=${token}"
    echo "MASTER_IP=${NODE_IP}"
    echo "ENV_MODE=baremetal"
    echo "STACKFORGE_VERSION=${STACKFORGE_VERSION}"
  } > "${STATE_FILE}"
  chmod 600 "${STATE_FILE}"

  _print_worker_box "${token}"
  prompt_yn "Have you joined your worker nodes yet? (open another terminal now)" "n" || true
}

bootstrap_k3s_worker() {
  section "Joining Cluster as Worker Node"
  local master_ip
  master_ip=$(prompt_input "Master node IP address")
  local token
  token=$(prompt_input "Node token (from ${STATE_FILE} on master)")
  info "Joining ${master_ip}..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" \
    K3S_URL="https://${master_ip}:6443" \
    K3S_TOKEN="${token}" \
    sh -
  sudo systemctl enable --now k3s-agent
  ok "Worker joined. On master: KUBECONFIG=~/.stackforge/kubeconfig kubectl get nodes"
}

_print_worker_box() {
  local token="$1"
  local token_short
  token_short=$(printf '%.24s' "$token")
  echo ""
  printf "  ${BYELLOW}╔═══════════════════════════════════════════════════════════════╗${RESET}\n"
  printf "  ${BYELLOW}║  Add Worker Nodes (run one of these on each worker)           ║${RESET}\n"
  printf "  ${BYELLOW}║                                                               ║${RESET}\n"
  printf "  ${BYELLOW}║  Option A — guided wizard:                                    ║${RESET}\n"
  printf "  ${BYELLOW}║    sh stackforge.sh --worker                                  ║${RESET}\n"
  printf "  ${BYELLOW}║                                                               ║${RESET}\n"
  printf "  ${BYELLOW}║  Option B — one-liner:                                        ║${RESET}\n"
  printf "  ${BYELLOW}║    curl -sfL https://get.k3s.io | \\\\                           ║${RESET}\n"
  printf "  ${BYELLOW}║      K3S_URL=https://%s:6443 \\\\                    ║${RESET}\n" "${NODE_IP}"
  printf "  ${BYELLOW}║      K3S_TOKEN=%s... \\\\     ║${RESET}\n" "${token_short}"
  printf "  ${BYELLOW}║      sh -                                                     ║${RESET}\n"
  printf "  ${BYELLOW}║                                                               ║${RESET}\n"
  printf "  ${BYELLOW}║  Full token in: ~/.stackforge/state.env                       ║${RESET}\n"
  printf "  ${BYELLOW}╚═══════════════════════════════════════════════════════════════╝${RESET}\n"
  echo ""
}

# ─── Services ────────────────────────────────────────────────
install_traefik() {
  section "Installing Traefik Ingress Controller"
  hm repo add traefik https://traefik.github.io/charts --force-update >/dev/null 2>&1
  hm repo update >/dev/null 2>&1
  kc create namespace traefik --dry-run=client -o yaml | kc apply -f - >/dev/null 2>&1
  hm upgrade --install traefik traefik/traefik \
    --namespace traefik \
    --set service.type=NodePort \
    --set "ports.web.nodePort=${PORT_TRAEFIK_HTTP}" \
    --set "ports.websecure.nodePort=${PORT_TRAEFIK_HTTPS}" \
    --set "ports.traefik.expose.default=true" \
    --set "ports.traefik.exposedPort=9000" \
    --set "ports.traefik.nodePort=${PORT_TRAEFIK_DASH}" \
    --set "ingressRoute.dashboard.enabled=true" \
    --wait --timeout 5m
  ok "Traefik Dashboard → http://${ACCESS_HOST}:${PORT_TRAEFIK_DASH}/dashboard/"
  ok "Traefik HTTP      → http://${ACCESS_HOST}:${PORT_TRAEFIK_HTTP}"
  svc_add "Traefik Dashboard|http://${ACCESS_HOST}:${PORT_TRAEFIK_DASH}/dashboard/|Ingress Controller"
}

install_portainer() {
  section "Installing Portainer CE"
  kc create namespace portainer --dry-run=client -o yaml | kc apply -f - >/dev/null 2>&1
  hm repo add portainer https://portainer.github.io/k8s/ --force-update >/dev/null 2>&1
  hm repo update >/dev/null 2>&1
  hm upgrade --install portainer portainer/portainer \
    --namespace portainer \
    --set service.type=NodePort \
    --set "service.nodePort=${PORT_PORTAINER_HTTP}" \
    --set "service.httpsNodePort=${PORT_PORTAINER_HTTPS}" \
    --wait --timeout 5m

  # Set admin password via Portainer's first-boot API endpoint
  info "Configuring Portainer admin password..."
  local attempts=0
  while [ $attempts -lt 30 ]; do
    if curl -fsSk "https://${ACCESS_HOST}:${PORT_PORTAINER_HTTPS}/api/users/admin/init" \
      -H "Content-Type: application/json" \
      -d "{\"Username\":\"admin\",\"Password\":\"${PORTAINER_PASS}\"}" >/dev/null 2>&1; then
      ok "Portainer admin password configured"
      break
    fi
    attempts=$((attempts + 1))
    sleep 2
  done
  if [ $attempts -ge 30 ]; then
    warn "Could not set Portainer password via API (may need manual setup)"
  fi
  ok "Portainer → https://${ACCESS_HOST}:${PORT_PORTAINER_HTTPS}  (admin / <generated>)"
  svc_add "Portainer|https://${ACCESS_HOST}:${PORT_PORTAINER_HTTPS}|Container Management"
}

install_monitoring() {
  section "Installing Prometheus + Grafana"
  hm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts --force-update >/dev/null 2>&1
  hm repo update >/dev/null 2>&1
  kc create namespace monitoring --dry-run=client -o yaml | kc apply -f - >/dev/null 2>&1
  hm upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --set "grafana.service.type=NodePort" \
    --set "grafana.service.nodePort=${PORT_GRAFANA}" \
    --set "grafana.admin.existingSecret=stackforge-credentials" \
    --set "grafana.admin.userKey=grafana-admin-user" \
    --set "grafana.admin.passwordKey=grafana-admin-password" \
    --set "prometheus.service.type=NodePort" \
    --set "prometheus.service.nodePort=${PORT_PROMETHEUS}" \
    --set "alertmanager.enabled=false" \
    --wait --timeout 10m
  ok "Grafana    → http://${ACCESS_HOST}:${PORT_GRAFANA}  (admin / <generated>)"
  ok "Prometheus → http://${ACCESS_HOST}:${PORT_PROMETHEUS}"
  svc_add "Grafana|http://${ACCESS_HOST}:${PORT_GRAFANA}|Metrics & Dashboards"
  svc_add "Prometheus|http://${ACCESS_HOST}:${PORT_PROMETHEUS}|Metrics Backend"
}

install_uptime_kuma() {
  section "Installing Uptime Kuma"
  kc create namespace monitoring --dry-run=client -o yaml | kc apply -f - >/dev/null 2>&1
  kc apply -f "${REPO_RAW}/manifests/uptime-kuma/uptime-kuma.yaml" 2>/dev/null \
    || kc apply -f "${REPO_LOCAL}/manifests/uptime-kuma/uptime-kuma.yaml"
  ok "Uptime Kuma → http://${ACCESS_HOST}:${PORT_UPTIME_KUMA}"
  svc_add "Uptime Kuma|http://${ACCESS_HOST}:${PORT_UPTIME_KUMA}|Status Monitoring"
}

install_dashboard() {
  section "Installing Stackforge Portal Dashboard"
  kc create namespace stackforge --dry-run=client -o yaml | kc apply -f - >/dev/null 2>&1

  local html="${REPO_LOCAL}/dashboard/index.html"
  if [ ! -f "${html}" ]; then
    mkdir -p "${STACKFORGE_DIR}/dashboard"
    curl -fsSL "${REPO_RAW}/dashboard/index.html" -o "${STACKFORGE_DIR}/dashboard/index.html"
    html="${STACKFORGE_DIR}/dashboard/index.html"
  fi

  kc create configmap stackforge-dashboard \
    --from-file=index.html="${html}" \
    --namespace stackforge \
    --dry-run=client -o yaml | kc apply -f -

  kc apply -f "${REPO_RAW}/manifests/dashboard/dashboard.yaml" 2>/dev/null \
    || kc apply -f "${REPO_LOCAL}/manifests/dashboard/dashboard.yaml"

  ok "Dashboard → http://${ACCESS_HOST}:${PORT_DASHBOARD}"
  svc_add "Stackforge Portal|http://${ACCESS_HOST}:${PORT_DASHBOARD}|Your Homelab Portal"
}

# ─── Destroy ──────────────────────────────────────────────────
destroy_cluster() {
  section "Destroy Stackforge"
  warn "This destroys the stackforge cluster and all data inside it."
  warn "Your existing ~/.kube/config and other clusters are NOT affected."
  prompt_yn "Proceed with destroy?" "n" || { info "Aborted."; exit 0; }

  case "${ENV_MODE}" in
    docker-desktop|wsl2)
      k3d cluster list 2>/dev/null | grep -q "^${K3D_CLUSTER_NAME}" \
        && k3d cluster delete "${K3D_CLUSTER_NAME}" && ok "k3d cluster deleted." || true
      ;;
    baremetal)
      command -v k3s-uninstall.sh >/dev/null 2>&1 \
        && sudo k3s-uninstall.sh && ok "k3s master uninstalled." || true
      command -v k3s-agent-uninstall.sh >/dev/null 2>&1 \
        && sudo k3s-agent-uninstall.sh && ok "k3s agent uninstalled." || true
      ;;
  esac

  prompt_yn "Remove ~/.stackforge directory?" "n" \
    && rm -rf "${STACKFORGE_DIR}" && ok "~/.stackforge removed." || true

  ok "Done. ~/.kube/config was never touched."
}

# ─── kubeconfig Hint Box ──────────────────────────────────────
print_kubeconfig_hint() {
  echo ""
  printf "  ${BYELLOW}╔═══════════════════════════════════════════════════════════════╗${RESET}\n"
  printf "  ${BYELLOW}║  Accessing your cluster                                       ║${RESET}\n"
  printf "  ${BYELLOW}║                                                               ║${RESET}\n"
  printf "  ${BYELLOW}║  stackforge NEVER touches ~/.kube/config                     ║${RESET}\n"
  printf "  ${BYELLOW}║                                                               ║${RESET}\n"
  printf "  ${BYELLOW}║  One-off:                                                     ║${RESET}\n"
  printf "  ${BYELLOW}║    KUBECONFIG=~/.stackforge/kubeconfig kubectl get nodes      ║${RESET}\n"
  printf "  ${BYELLOW}║                                                               ║${RESET}\n"
  printf "  ${BYELLOW}║  Alias (add to ~/.bashrc or ~/.zshrc):                        ║${RESET}\n"
  printf "  ${BYELLOW}║    alias sfk='KUBECONFIG=~/.stackforge/kubeconfig kubectl'    ║${RESET}\n"
  printf "  ${BYELLOW}║                                                               ║${RESET}\n"
  printf "  ${BYELLOW}║  Temporary shell switch:                                      ║${RESET}\n"
  printf "  ${BYELLOW}║    export KUBECONFIG=~/.stackforge/kubeconfig                 ║${RESET}\n"
  printf "  ${BYELLOW}╚═══════════════════════════════════════════════════════════════╝${RESET}\n"
  echo ""
}

# ─── Summary ──────────────────────────────────────────────────
print_summary() {
  echo ""
  printf "${BCYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  printf "${BGREEN}  🚀  Stackforge complete!  [mode: %s]${RESET}\n" "${ENV_MODE}"
  printf "${BCYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n\n"
  printf "  ${BOLD}Cluster nodes:${RESET}\n"
  kc get nodes 2>/dev/null | sed 's/^/    /' || true
  echo ""
  if [ "$(svc_count)" -gt 0 ]; then
    printf "  ${BOLD}Installed services:${RESET}\n"
    printf '%s\n' "$INSTALLED_SERVICES" | while IFS='|' read -r name url desc; do
      printf "    ${BGREEN}%-24s${RESET} ${CYAN}%-48s${RESET} ${DIM}%s${RESET}\n" "${name}" "${url}" "${desc}"
    done
    echo ""
    printf "  ${BYELLOW}→ Open your portal: http://%s:%s${RESET}\n" "${ACCESS_HOST}" "${PORT_DASHBOARD}"
  fi
  echo ""
  printf "  ${BOLD}Recommended Uptime Kuma monitors:${RESET}\n"
  printf "    ${DIM}• Grafana       → http://%s:%s/api/health${RESET}\n" "${ACCESS_HOST}" "${PORT_GRAFANA}"
  printf "    ${DIM}• Prometheus    → http://%s:%s/-/healthy${RESET}\n" "${ACCESS_HOST}" "${PORT_PROMETHEUS}"
  printf "    ${DIM}• Traefik       → http://%s:%s/dashboard/${RESET}\n" "${ACCESS_HOST}" "${PORT_TRAEFIK_DASH}"
  printf "    ${DIM}• Portainer     → https://%s:%s${RESET}\n" "${ACCESS_HOST}" "${PORT_PORTAINER_HTTPS}"
  printf "    ${DIM}• Dashboard     → http://%s:%s${RESET}\n" "${ACCESS_HOST}" "${PORT_DASHBOARD}"
  printf "    ${DIM}• Uptime Kuma   → http://%s:%s${RESET}\n" "${ACCESS_HOST}" "${PORT_UPTIME_KUMA}"
  echo ""
  if [ -n "${GRAFANA_PASS:-}" ] && [ -n "${PORTAINER_PASS:-}" ]; then
    printf "  ${BOLD}Credentials (randomly generated):${RESET}\n"
    printf "    ${BGREEN}Grafana${RESET}    admin / ${BCYAN}%s${RESET}\n" "${GRAFANA_PASS}"
    printf "    ${BGREEN}Portainer${RESET}  admin / ${BCYAN}%s${RESET}\n" "${PORTAINER_PASS}"
    echo ""
    printf "  ${DIM}View later:  cat %s${RESET}\n" "${STATE_FILE}"
    printf "  ${DIM}Reset all:   bash stackforge.sh --reset-passwords${RESET}\n"
    echo ""
  fi
  printf "  ${DIM}Kubeconfig : %s${RESET}\n" "${STACKFORGE_KUBECONFIG}"
  printf "  ${DIM}Log file   : %s${RESET}\n" "${LOG_FILE}"
  [ -f "${STATE_FILE}" ] && printf "  ${DIM}State file : %s${RESET}\n" "${STATE_FILE}"
  print_kubeconfig_hint
}

# ─── Main ────────────────────────────────────────────────────
main() {
  banner
  detect_environment

  case "${1:-}" in
    --worker)
      [ "${ENV_MODE}" = "baremetal" ] || die "--worker is only for bare-metal Linux."
      check_prerequisites
      install_kubectl
      bootstrap_k3s_worker
      exit 0
      ;;
    --destroy)
      destroy_cluster
      exit 0
      ;;
    --kubeconfig)
      echo "${STACKFORGE_KUBECONFIG}"
      exit 0
      ;;
    --reset-passwords)
      check_prerequisites
      reset_passwords
      exit 0
      ;;
  esac

  check_prerequisites

  printf "  ${BOLD}Welcome to Stackforge!${RESET}\n"
  printf "  ${DIM}Mode:       ${BCYAN}%s${RESET}\n" "${ENV_MODE}"
  printf "  ${DIM}Access at:  ${BCYAN}%s${RESET}\n" "${ACCESS_HOST}"
  printf "  ${DIM}Kubeconfig: ${BCYAN}%s${RESET}  ${DIM}(~/.kube/config will NOT be touched)${RESET}\n" "${STACKFORGE_KUBECONFIG}"
  printf "  ${DIM}Every component is optional except the cluster itself.${RESET}\n\n"

  # Phase 0 — tooling
  section "Phase 0: Tooling"
  install_kubectl
  install_helm

  # Phase 1 — cluster
  section "Phase 1: Cluster Bootstrap"
  case "${ENV_MODE}" in
    docker-desktop|wsl2)
      install_k3d
      bootstrap_k3d
      ;;
    baremetal)
      prompt_yn "Install Docker Engine (for local image builds alongside k3s)" \
        && install_docker_baremetal || true
      bootstrap_k3s_master
      ;;
  esac

  # Credentials — create secret before installing services
  create_credentials_secret

  # Phase 2 — ingress
  section "Phase 2: Ingress"
  prompt_yn "Install Traefik ingress controller (recommended)" \
    && install_traefik || true

  # Phase 3 — management
  section "Phase 3: Cluster Management"
  prompt_yn "Install Portainer CE (GUI for containers & Kubernetes)" \
    && install_portainer || true

  # Phase 4 — observability
  section "Phase 4: Observability"
  prompt_yn "Install Prometheus + Grafana (metrics & dashboards)" \
    && install_monitoring || true
  prompt_yn "Install Uptime Kuma (service health monitoring)" \
    && install_uptime_kuma || true

  # Phase 5 — portal
  section "Phase 5: Stackforge Portal"
  prompt_yn "Install the Stackforge portal dashboard (recommended)" \
    && install_dashboard || true

  print_summary
}

main "$@"
