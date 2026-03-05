#!/usr/bin/env bash
# ============================================================
#  ███████╗████████╗ █████╗  ██████╗██╗  ██╗███████╗ ██████╗ ██████╗  ██████╗ ███████╗
#  ██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝
#  ███████╗   ██║   ███████║██║     █████╔╝ █████╗  ██║   ██║██████╔╝██║  ███╗█████╗
#  ╚════██║   ██║   ██╔══██║██║     ██╔═██╗ ██╔══╝  ██║   ██║██╔══██╗██║   ██║██╔══╝
#  ███████║   ██║   ██║  ██║╚██████╗██║  ██╗██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗
#  ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝
#
#  stackforge v0.3.2 — guided homelab infrastructure bootstrapper
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
#    curl -fsSL https://raw.githubusercontent.com/ry-ops/stackforge/main/stackforge.sh | bash
#
#  Subcommands:
#    --worker     Join this machine to an existing stackforge bare-metal cluster
#    --destroy    Tear down the stackforge cluster (safe, isolated)
#    --kubeconfig Print path to the stackforge kubeconfig file
# ============================================================

set -euo pipefail

# ─── Globals ────────────────────────────────────────────────
STACKFORGE_VERSION="0.3.4"
STACKFORGE_DIR="${HOME}/.stackforge"
STACKFORGE_KUBECONFIG="${STACKFORGE_DIR}/kubeconfig"  # NEVER ~/.kube/config
STATE_FILE="${STACKFORGE_DIR}/state.env"
LOG_FILE="${STACKFORGE_DIR}/stackforge.log"
K3S_VERSION="v1.29.4+k3s1"
K3D_CLUSTER_NAME="stackforge"
REPO_RAW="https://raw.githubusercontent.com/ry-ops/stackforge/main"
REPO_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "${HOME}/.stackforge")"

# Port assignments
PORT_DASHBOARD=30080
PORT_PORTAINER_HTTP=30777
PORT_PORTAINER_HTTPS=30779
PORT_TRAEFIK_HTTP=32080
PORT_TRAEFIK_HTTPS=32443
PORT_GRAFANA=32000
PORT_PROMETHEUS=32001
PORT_UPTIME_KUMA=32100

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
INSTALLED_SERVICES=()

# ─── Colors ─────────────────────────────────────────────────
RESET='\033[0m';    BOLD='\033[1m';     DIM='\033[2m'
RED='\033[0;31m';   GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m';  WHITE='\033[0;37m'
BGREEN='\033[1;32m'; BCYAN='\033[1;36m'; BYELLOW='\033[1;33m'; BRED='\033[1;31m'

# ─── Logging ─────────────────────────────────────────────────
mkdir -p "${STACKFORGE_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log()     { echo -e "${DIM}$(date '+%H:%M:%S')${RESET} ${WHITE}$*${RESET}"; }
info()    { echo -e "${CYAN}  →${RESET} $*"; }
ok()      { echo -e "${BGREEN}  ✔${RESET} $*"; }
warn()    { echo -e "${BYELLOW}  ⚠${RESET} $*"; }
err()     { echo -e "${BRED}  ✖${RESET} $*" >&2; }
die()     { err "$*"; exit 1; }
section() { echo -e "\n${BCYAN}━━━ ${BOLD}$*${RESET}${BCYAN} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"; }

banner() {
  echo -e "${BCYAN}"
  cat << 'BANNER'
  ███████╗████████╗ █████╗  ██████╗██╗  ██╗███████╗ ██████╗ ██████╗  ██████╗ ███████╗
  ██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝
  ███████╗   ██║   ███████║██║     █████╔╝ █████╗  ██║   ██║██████╔╝██║  ███╗█████╗
  ╚════██║   ██║   ██╔══██║██║     ██╔═██╗ ██╔══╝  ██║   ██║██╔══██╗██║   ██║██╔══╝
  ███████║   ██║   ██║  ██║╚██████╗██║  ██╗██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗
  ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝
BANNER
  echo -e "${RESET}"
  echo -e "  ${DIM}v${STACKFORGE_VERSION} — guided homelab infrastructure bootstrapper${RESET}"
  echo -e "  ${DIM}github.com/ry-ops/stackforge${RESET}\n"
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
  [[ "$default" == "y" ]] \
    && display="${BGREEN}Y${RESET}${DIM}/n${RESET}" \
    || display="${DIM}y/${RESET}${RED}N${RESET}"
  echo -ne "  ${CYAN}?${RESET} ${q} [${display}] "
  read -r reply; reply="${reply:-$default}"
  [[ "${reply,,}" == "y" ]]
}

prompt_input() {
  local q="$1" default="${2:-}"
  [[ -n "$default" ]] \
    && echo -ne "  ${CYAN}?${RESET} ${q} ${DIM}[${default}]${RESET} " \
    || echo -ne "  ${CYAN}?${RESET} ${q} "
  read -r reply; echo "${reply:-$default}"
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

  local kernel; kernel=$(uname -s)

  # ── macOS ──────────────────────────────────────────────────
  if [[ "$kernel" == "Darwin" ]]; then
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
  if [[ -f /proc/version ]] && grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
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
  [[ -f /etc/os-release ]] || die "/etc/os-release missing — cannot identify Linux distro."
  # shellcheck source=/dev/null
  source /etc/os-release
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
  if ! command -v docker &>/dev/null; then
    echo ""
    err "Docker Desktop not found. Please install it first:"
    echo -e "  ${DIM}macOS:   https://docs.docker.com/desktop/install/mac-install/${RESET}"
    echo -e "  ${DIM}Windows: https://docs.docker.com/desktop/install/windows-install/${RESET}"
    echo ""
    die "Docker Desktop is required for this environment."
  fi
  if ! docker info &>/dev/null; then
    die "Docker is installed but not running. Start Docker Desktop first, then re-run stackforge."
  fi
  DOCKER_INSTALLED=true
  ok "Docker Desktop: running ✓"
}

# ─── Package Manager (bare-metal only) ───────────────────────
pkg_update() {
  [[ "${ENV_MODE}" == "baremetal" ]] || return 0
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
  [[ "${ENV_MODE}" == "baremetal" ]] || return 0
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

  if [[ "${ENV_MODE}" == "baremetal" ]]; then
    [[ $EUID -ne 0 ]] || die "Don't run as root. stackforge uses sudo internally."
    command -v sudo &>/dev/null || die "sudo is required but not installed."
    local missing=()
    for cmd in curl; do command -v "$cmd" &>/dev/null || missing+=("$cmd"); done
    if [[ ${#missing[@]} -gt 0 ]]; then
      pkg_update; pkg_install "${missing[@]}"
    fi
  fi

  command -v k3s  &>/dev/null && K3S_INSTALLED=true  && ok "k3s:  already installed"
  command -v k3d  &>/dev/null && K3D_INSTALLED=true  && ok "k3d:  already installed"
  command -v helm &>/dev/null && HELM_INSTALLED=true && ok "Helm: already installed"

  # Warn but NEVER touch existing kubeconfig
  if [[ -f "${HOME}/.kube/config" ]]; then
    local n; n=$(kubectl config get-contexts --no-headers 2>/dev/null | wc -l || echo "?")
    warn "Found existing ~/.kube/config (${n} context(s)) — stackforge will NOT touch it."
    warn "All stackforge access uses: ${STACKFORGE_KUBECONFIG}"
  fi
}

# ─── Tooling ──────────────────────────────────────────────────
install_kubectl() {
  command -v kubectl &>/dev/null && { ok "kubectl: already installed"; return; }
  info "Installing kubectl..."
  local ver; ver=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  case "${OS_FAMILY}" in
    darwin)
      if command -v brew &>/dev/null; then
        brew install kubectl &>/dev/null
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
  [[ "${HELM_INSTALLED}" == "true" ]] && { ok "Helm: already installed"; return; }
  info "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | bash -s -- --no-sudo
  HELM_INSTALLED=true
  ok "Helm installed."
}

install_k3d() {
  [[ "${K3D_INSTALLED}" == "true" ]] && { ok "k3d: already installed"; return; }
  info "Installing k3d (k3s-in-Docker)..."
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
  K3D_INSTALLED=true
  ok "k3d installed."
}

# ─── Docker Engine (bare-metal only) ─────────────────────────
install_docker_baremetal() {
  section "Installing Docker Engine"
  [[ "${DOCKER_INSTALLED}" == "true" ]] && { info "Docker already installed."; return; }

  # shellcheck source=/dev/null
  [[ -f /etc/os-release ]] && source /etc/os-release

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
  echo -e "  ${DIM}Mode: k3s running inside Docker Desktop containers${RESET}"
  echo -e "  ${DIM}1 control-plane + 2 worker nodes. No root. No systemd. Fully isolated.${RESET}\n"

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
    sleep 4; t=$((t+4)); [[ $t -ge 120 ]] && die "Timed out waiting for cluster."
    echo -ne "  ${DIM}waiting... ${t}s${RESET}\r"
  done
  echo ""
  ok "Cluster ready:"
  kc get nodes | sed 's/^/    /'
}

# ─── Cluster Bootstrap: Bare-metal (k3s) ─────────────────────
bootstrap_k3s_master() {
  section "Bootstrapping k3s Control Plane"

  if [[ "${K3S_INSTALLED}" == "true" ]]; then
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
    sleep 5; t=$((t+5)); [[ $t -ge 120 ]] && die "Timed out waiting for k3s."
    echo -ne "  ${DIM}waiting... ${t}s${RESET}\r"
  done
  echo ""
  ok "Control plane Ready."

  # Save state for workers
  local token; token=$(sudo cat /var/lib/rancher/k3s/server/node-token)
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
  local master_ip; master_ip=$(prompt_input "Master node IP address")
  local token;     token=$(prompt_input "Node token (from ${STATE_FILE} on master)")
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
  echo ""
  echo -e "  ${BYELLOW}╔═══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "  ${BYELLOW}║  Add Worker Nodes (run one of these on each worker)           ║${RESET}"
  echo -e "  ${BYELLOW}║                                                               ║${RESET}"
  echo -e "  ${BYELLOW}║  Option A — guided wizard:                                    ║${RESET}"
  echo -e "  ${BYELLOW}║    bash stackforge.sh --worker                                ║${RESET}"
  echo -e "  ${BYELLOW}║                                                               ║${RESET}"
  echo -e "  ${BYELLOW}║  Option B — one-liner:                                        ║${RESET}"
  echo -e "  ${BYELLOW}║    curl -sfL https://get.k3s.io | \\                           ║${RESET}"
  printf   "  ${BYELLOW}║      K3S_URL=https://%s:6443 \\                    ║${RESET}\n" "${NODE_IP}"
  printf   "  ${BYELLOW}║      K3S_TOKEN=%s... \\     ║${RESET}\n" "${token:0:24}"
  echo -e "  ${BYELLOW}║      sh -                                                     ║${RESET}"
  echo -e "  ${BYELLOW}║                                                               ║${RESET}"
  echo -e "  ${BYELLOW}║  Full token in: ~/.stackforge/state.env                       ║${RESET}"
  echo -e "  ${BYELLOW}╚═══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

# ─── Services ────────────────────────────────────────────────
install_traefik() {
  section "Installing Traefik Ingress Controller"
  hm repo add traefik https://traefik.github.io/charts --force-update &>/dev/null
  hm repo update &>/dev/null
  kc create namespace traefik --dry-run=client -o yaml | kc apply -f - &>/dev/null
  hm upgrade --install traefik traefik/traefik \
    --namespace traefik \
    --set service.type=NodePort \
    --set "ports.web.nodePort=${PORT_TRAEFIK_HTTP}" \
    --set "ports.websecure.nodePort=${PORT_TRAEFIK_HTTPS}" \
    --set "ingressRoute.dashboard.enabled=true" \
    --wait --timeout 5m
  ok "Traefik → http://${ACCESS_HOST}:${PORT_TRAEFIK_HTTP}/dashboard/"
  INSTALLED_SERVICES+=("Traefik|http://${ACCESS_HOST}:${PORT_TRAEFIK_HTTP}/dashboard/|Ingress Controller")
}

install_portainer() {
  section "Installing Portainer CE"
  kc create namespace portainer --dry-run=client -o yaml | kc apply -f - &>/dev/null
  hm repo add portainer https://portainer.github.io/k8s/ --force-update &>/dev/null
  hm repo update &>/dev/null
  hm upgrade --install portainer portainer/portainer \
    --namespace portainer \
    --set service.type=NodePort \
    --set "service.nodePort=${PORT_PORTAINER_HTTP}" \
    --set "service.httpsNodePort=${PORT_PORTAINER_HTTPS}" \
    --wait --timeout 5m
  ok "Portainer → https://${ACCESS_HOST}:${PORT_PORTAINER_HTTPS}"
  INSTALLED_SERVICES+=("Portainer|https://${ACCESS_HOST}:${PORT_PORTAINER_HTTPS}|Container Management")
}

install_monitoring() {
  section "Installing Prometheus + Grafana"
  hm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts --force-update &>/dev/null
  hm repo update &>/dev/null
  kc create namespace monitoring --dry-run=client -o yaml | kc apply -f - &>/dev/null
  hm upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --set "grafana.service.type=NodePort" \
    --set "grafana.service.nodePort=${PORT_GRAFANA}" \
    --set "grafana.adminPassword=stackforge" \
    --set "prometheus.service.type=NodePort" \
    --set "prometheus.prometheusSpec.service.nodePort=${PORT_PROMETHEUS}" \
    --set "alertmanager.enabled=false" \
    --wait --timeout 10m
  ok "Grafana    → http://${ACCESS_HOST}:${PORT_GRAFANA}  (admin / stackforge)"
  ok "Prometheus → http://${ACCESS_HOST}:${PORT_PROMETHEUS}"
  warn "Change the Grafana admin password after first login!"
  INSTALLED_SERVICES+=("Grafana|http://${ACCESS_HOST}:${PORT_GRAFANA}|Metrics & Dashboards")
  INSTALLED_SERVICES+=("Prometheus|http://${ACCESS_HOST}:${PORT_PROMETHEUS}|Metrics Backend")
}

install_uptime_kuma() {
  section "Installing Uptime Kuma"
  kc create namespace monitoring --dry-run=client -o yaml | kc apply -f - &>/dev/null
  kc apply -f "${REPO_RAW}/manifests/uptime-kuma/uptime-kuma.yaml" 2>/dev/null \
    || kc apply -f "${REPO_LOCAL}/manifests/uptime-kuma/uptime-kuma.yaml"
  ok "Uptime Kuma → http://${ACCESS_HOST}:${PORT_UPTIME_KUMA}"
  INSTALLED_SERVICES+=("Uptime Kuma|http://${ACCESS_HOST}:${PORT_UPTIME_KUMA}|Status Monitoring")
}

install_dashboard() {
  section "Installing Stackforge Portal Dashboard"
  kc create namespace stackforge --dry-run=client -o yaml | kc apply -f - &>/dev/null

  local html="${REPO_LOCAL}/dashboard/index.html"
  if [[ ! -f "${html}" ]]; then
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
  INSTALLED_SERVICES+=("Stackforge Portal|http://${ACCESS_HOST}:${PORT_DASHBOARD}|Your Homelab Portal")
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
      command -v k3s-uninstall.sh &>/dev/null \
        && sudo k3s-uninstall.sh && ok "k3s master uninstalled." || true
      command -v k3s-agent-uninstall.sh &>/dev/null \
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
  echo -e "  ${BYELLOW}╔═══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "  ${BYELLOW}║  Accessing your cluster                                       ║${RESET}"
  echo -e "  ${BYELLOW}║                                                               ║${RESET}"
  echo -e "  ${BYELLOW}║  stackforge NEVER touches ~/.kube/config                     ║${RESET}"
  echo -e "  ${BYELLOW}║                                                               ║${RESET}"
  echo -e "  ${BYELLOW}║  One-off:                                                     ║${RESET}"
  echo -e "  ${BYELLOW}║    KUBECONFIG=~/.stackforge/kubeconfig kubectl get nodes      ║${RESET}"
  echo -e "  ${BYELLOW}║                                                               ║${RESET}"
  echo -e "  ${BYELLOW}║  Alias (add to ~/.bashrc or ~/.zshrc):                        ║${RESET}"
  echo -e "  ${BYELLOW}║    alias sfk='KUBECONFIG=~/.stackforge/kubeconfig kubectl'    ║${RESET}"
  echo -e "  ${BYELLOW}║                                                               ║${RESET}"
  echo -e "  ${BYELLOW}║  Temporary shell switch:                                      ║${RESET}"
  echo -e "  ${BYELLOW}║    export KUBECONFIG=~/.stackforge/kubeconfig                 ║${RESET}"
  echo -e "  ${BYELLOW}╚═══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

# ─── Summary ──────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BCYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BGREEN}  🚀  Stackforge complete!  [mode: ${ENV_MODE}]${RESET}"
  echo -e "${BCYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  echo -e "  ${BOLD}Cluster nodes:${RESET}"
  kc get nodes 2>/dev/null | sed 's/^/    /' || true
  echo ""
  if [[ ${#INSTALLED_SERVICES[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Installed services:${RESET}"
    for svc in "${INSTALLED_SERVICES[@]}"; do
      IFS='|' read -r name url desc <<< "${svc}"
      printf "    ${BGREEN}%-24s${RESET} ${CYAN}%-48s${RESET} ${DIM}%s${RESET}\n" "${name}" "${url}" "${desc}"
    done
    echo ""
    echo -e "  ${BYELLOW}→ Open your portal: http://${ACCESS_HOST}:${PORT_DASHBOARD}${RESET}"
  fi
  echo ""
  echo -e "  ${DIM}Kubeconfig : ${STACKFORGE_KUBECONFIG}${RESET}"
  echo -e "  ${DIM}Log file   : ${LOG_FILE}${RESET}"
  [[ -f "${STATE_FILE}" ]] && echo -e "  ${DIM}State file : ${STATE_FILE}${RESET}"
  print_kubeconfig_hint
}

# ─── Main ────────────────────────────────────────────────────
main() {
  banner
  detect_environment

  case "${1:-}" in
    --worker)
      [[ "${ENV_MODE}" == "baremetal" ]] || die "--worker is only for bare-metal Linux."
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
  esac

  check_prerequisites

  echo -e "  ${BOLD}Welcome to Stackforge!${RESET}"
  echo -e "  ${DIM}Mode:       ${BCYAN}${ENV_MODE}${RESET}"
  echo -e "  ${DIM}Access at:  ${BCYAN}${ACCESS_HOST}${RESET}"
  echo -e "  ${DIM}Kubeconfig: ${BCYAN}${STACKFORGE_KUBECONFIG}${RESET}  ${DIM}(~/.kube/config will NOT be touched)${RESET}"
  echo -e "  ${DIM}Every component is optional except the cluster itself.${RESET}\n"

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
