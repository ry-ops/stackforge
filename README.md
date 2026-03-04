# STACKFORGE

> A guided homelab infrastructure bootstrapper. One script. Choose your adventure.

```
  ███████╗████████╗ █████╗  ██████╗██╗  ██╗███████╗ ██████╗ ██████╗  ██████╗ ███████╗
  ██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝
  ███████╗   ██║   ███████║██║     █████╔╝ █████╗  ██║   ██║██████╔╝██║  ███╗█████╗
  ╚════██║   ██║   ██╔══██║██║     ██╔═██╗ ██╔══╝  ██║   ██║██╔══██╗██║   ██║██╔══╝
  ███████║   ██║   ██║  ██║╚██████╗██║  ██╗██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗
  ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝
```

[![License: MIT](https://img.shields.io/badge/License-MIT-cyan.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-linux%20%7C%20macOS%20%7C%20WSL2-blue.svg)]()
[![k3s](https://img.shields.io/badge/k8s-k3s%20%7C%20k3d-orange.svg)](https://k3s.io)
[![GHCR](https://img.shields.io/badge/container-ghcr.io-purple.svg)](https://github.com/ry-ops/stackforge/pkgs/container/stackforge)

---

## What is stackforge?

stackforge is a single bash script that walks you through building a homelab Kubernetes cluster from scratch — with interactive prompts at every step. No config files to edit before running. No YAML to write on day one. No guessing.

It installs and configures:

| Phase | Component | What it does |
|-------|-----------|--------------|
| Foundation | Docker + k3s/k3d | Container runtime and lightweight Kubernetes |
| Ingress | Traefik | Ingress controller with NodePort routing |
| Management | Portainer CE | GUI for your cluster and containers |
| Observability | Prometheus + Grafana | Full metrics stack with pre-built k8s dashboards |
| Observability | Uptime Kuma | Service health monitoring |
| Portal | Stackforge Dashboard | Unified web portal for all your services |

Everything is optional except the cluster itself. You choose what gets installed.

---

## Quick Start

### Bare-Metal Linux (k3s native)

```bash
curl -fsSL https://raw.githubusercontent.com/ry-ops/stackforge/main/stackforge.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/ry-ops/stackforge
cd stackforge
bash stackforge.sh
```

### Docker Desktop — macOS or Windows/WSL2 (k3d)

If you're on macOS or Windows with Docker Desktop installed, stackforge automatically detects the environment and uses **k3d** (k3s running inside Docker containers). No root access or systemd required.

```bash
bash stackforge.sh
```

### Worker Nodes (bare-metal only — run on each worker after master is set up)

```bash
bash stackforge.sh --worker
# OR the one-liner the master gives you at the end of Phase 1
```

### Docker Image

stackforge is also available as a container image:

```bash
docker pull ghcr.io/ry-ops/stackforge:latest
```

---

## How It Works

stackforge detects your environment before doing anything:

| Environment | Cluster Engine | How it works |
|------------|----------------|--------------|
| Bare-metal Linux | k3s (native binary, systemd) | Standard k3s install, 1 master + N workers |
| Docker Desktop (macOS) | k3d (k3s-in-Docker) | Full cluster inside Docker containers, no root |
| WSL2 (Windows) | k3d (k3s-in-Docker) | Same as macOS, runs inside WSL2 |
| Linux VM | k3s (detected as bare-metal) | Treated the same as bare-metal |

### Isolated Kubeconfig

stackforge **never** reads, writes, or merges `~/.kube/config`. All cluster access uses an isolated kubeconfig at:

```
~/.stackforge/kubeconfig
```

If you have existing clusters (Rancher Desktop, minikube, a work cluster), they are completely unaffected.

```bash
# One-off command
KUBECONFIG=~/.stackforge/kubeconfig kubectl get nodes

# Alias (add to ~/.bashrc or ~/.zshrc)
alias sfk='KUBECONFIG=~/.stackforge/kubeconfig kubectl'

# Print kubeconfig path
bash stackforge.sh --kubeconfig
```

---

## Supported Platforms

### Linux (bare-metal k3s)

| OS Family | Distros |
|-----------|---------|
| Debian/Ubuntu | Ubuntu 20.04+, Debian 11+, Raspberry Pi OS, Linux Mint, Pop!_OS |
| RHEL | RHEL 8+, CentOS Stream 8+, Rocky Linux 8+, AlmaLinux 8+, Oracle Linux |
| Fedora | Fedora 38+ |
| openSUSE | Leap 15+, SLES |
| Arch | Arch Linux, Manjaro, EndeavourOS |
| Alpine | Alpine 3.18+ |

### Docker Desktop (k3d)

| Platform | Requirement |
|----------|-------------|
| macOS | Docker Desktop installed and running |
| Windows | Docker Desktop + WSL2 |

**Architectures:** `x86_64`, `arm64/aarch64`, `armv7l` (Raspberry Pi 32-bit)

---

## What the Install Flow Looks Like

The example below shows a bare-metal install. Docker Desktop mode skips the Docker install and worker join steps, creating a k3d cluster with 1 control-plane + 2 agents automatically.

```
━━━ Phase 1: Foundation ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ? Install Docker (recommended for local image builds) [Y/n]
  ✔ Docker installed and started.
  → Installing k3s on master node...
  ✔ Control plane is Ready.

  ╔══════════════════════════════════════════════════╗
  ║  Worker Node Join Command                        ║
  ║  Run this on each worker node:                   ║
  ║  curl -fsSL https://get.k3s.io | \               ║
  ║    K3S_URL=https://192.168.1.100:6443 \           ║
  ║    K3S_TOKEN=K1075f3... \                         ║
  ║    sh -                                          ║
  ╚══════════════════════════════════════════════════╝

  ? Have you joined your worker nodes? [y/N]

━━━ Phase 2: Ingress ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ? Install Traefik ingress controller (recommended) [Y/n]

━━━ Phase 3: Cluster Management ━━━━━━━━━━━━━━━━━━━━
  ? Install Portainer CE (GUI for containers & k8s) [Y/n]

━━━ Phase 4: Observability ━━━━━━━━━━━━━━━━━━━━━━━━━
  ? Install Prometheus + Grafana (metrics & dashboards) [Y/n]
  ? Install Uptime Kuma (service status monitoring) [Y/n]

━━━ Phase 5: Stackforge Portal ━━━━━━━━━━━━━━━━━━━━━
  ? Install the Stackforge portal dashboard (recommended) [Y/n]

🚀  Stackforge complete!

  Cluster Nodes:
    NAME        STATUS   ROLES    AGE
    master-01   Ready    master   5m
    worker-01   Ready    <none>   3m
    worker-02   Ready    <none>   3m

  Portainer             https://192.168.1.100:30779   Container Management
  Grafana               http://192.168.1.100:32000    Metrics & Dashboards
  Prometheus            http://192.168.1.100:32001    Metrics Backend
  Uptime Kuma           http://192.168.1.100:32100    Status Monitoring
  Stackforge Dashboard  http://192.168.1.100:30080    Your Portal
```

---

## Default Port Map

| Service | NodePort | Protocol |
|---------|----------|----------|
| Stackforge Dashboard | 30080 | HTTP |
| Portainer | 30777 / 30779 | HTTP / HTTPS |
| Traefik HTTP | 32080 | HTTP |
| Traefik HTTPS | 32443 | HTTPS |
| Grafana | 32000 | HTTP |
| Prometheus | 32001 | HTTP |
| Uptime Kuma | 32100 | HTTP |

On Docker Desktop / WSL2, these ports map to `127.0.0.1` (localhost). On bare-metal, they map to the node's LAN IP.

---

## After Install

**Change Grafana's default password** — stackforge sets the initial password to `admin / stackforge`:

```bash
KUBECONFIG=~/.stackforge/kubeconfig kubectl exec -n monitoring \
  $(KUBECONFIG=~/.stackforge/kubeconfig kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o name) \
  -- grafana-cli admin reset-admin-password <newpassword>
```

**Check cluster health:**

```bash
KUBECONFIG=~/.stackforge/kubeconfig kubectl get nodes
KUBECONFIG=~/.stackforge/kubeconfig kubectl get pods -A
```

**Re-run to add more services:**

```bash
bash stackforge.sh
# Stackforge detects existing installs and skips them
```

**Tear down (safe — never touches ~/.kube/config):**

```bash
bash stackforge.sh --destroy
```

---

## Repo Structure

```
stackforge/
├── stackforge.sh                  # Main installer script
├── Dockerfile                     # Container image
├── .github/workflows/             # CI/CD (Docker publish)
├── manifests/
│   ├── uptime-kuma/
│   │   └── uptime-kuma.yaml       # Deployment + PVC + NodePort svc
│   └── dashboard/
│       └── dashboard.yaml         # nginx pod + NodePort svc
├── dashboard/
│   └── index.html                 # Stackforge portal UI
├── docs/
│   └── ...                        # Tutorial companion
└── README.md
```

---

## Philosophy

Stackforge is built around a few principles:

- **Guided, not scripted** — every decision is yours, explained in plain language
- **Lightweight first** — k3s over kubeadm, NodePort over LoadBalancer, single binary where possible
- **Idempotent** — safe to re-run, skips what's already installed
- **Isolated** — uses its own kubeconfig, never touches existing clusters
- **Cross-platform** — bare-metal Linux, Docker Desktop on macOS, WSL2 on Windows
- **Observable from minute one** — the dashboard is the first thing you see when it's done

---

## Companion Tutorial

Full walkthrough on ry-ops.dev: [Kubernetes at Home: A Practical Guide to Your First Cluster](https://ry-ops.dev/posts/2026-03-04-kubernetes-homelab-from-zero)

Covers what Kubernetes does, when it makes sense for a homelab, how to set up a cluster manually, and how stackforge automates the process.

---

## Contributing

PRs welcome. Open issues for distro support requests, new tool additions, or bug reports.

---

## License

MIT © [ry-ops](https://github.com/ry-ops)
