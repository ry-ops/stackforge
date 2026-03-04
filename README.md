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
[![Platform](https://img.shields.io/badge/platform-linux-blue.svg)]()
[![k3s](https://img.shields.io/badge/k8s-k3s-orange.svg)](https://k3s.io)

---

## What is stackforge?

stackforge is a single bash script that walks you through building a production-grade homelab Kubernetes cluster from scratch — with interactive prompts at every step. No config files to edit before running. No YAML to write on day one. No guessing.

It installs and configures:

| Phase | Component | What it does |
|-------|-----------|--------------|
| Foundation | Docker | Local image builds, compose workloads |
| Foundation | k3s | Lightweight Kubernetes (1 master, 2 workers) |
| Ingress | Traefik | Ingress controller with NodePort routing |
| Management | Portainer CE | GUI for your cluster and containers |
| Observability | Prometheus + Grafana | Full metrics stack with pre-built k8s dashboards |
| Observability | Uptime Kuma | Service health monitoring |
| Portal | Stackforge Dashboard | Unified web portal for all your services |

Everything is optional except k3s. You choose what gets installed.

---

## Quick Start

### Master Node

```bash
curl -fsSL https://raw.githubusercontent.com/ry-ops/stackforge/main/stackforge.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/ry-ops/stackforge
cd stackforge
bash stackforge.sh
```

### Worker Nodes (run on each worker after master is set up)

```bash
bash stackforge.sh --worker
# OR the one-liner the master gives you at the end of Phase 1
```

---

## Supported Platforms

| OS Family | Distros |
|-----------|---------|
| Debian/Ubuntu | Ubuntu 20.04+, Debian 11+, Raspberry Pi OS, Linux Mint, Pop!_OS |
| RHEL | RHEL 8+, CentOS Stream 8+, Rocky Linux 8+, AlmaLinux 8+, Oracle Linux |
| Fedora | Fedora 38+ |
| openSUSE | Leap 15+, SLES |
| Arch | Arch Linux, Manjaro, EndeavourOS |
| Alpine | Alpine 3.18+ |

**Architectures:** `x86_64`, `arm64/aarch64`, `armv7l` (Raspberry Pi 32-bit)

---

## What the install flow looks like

```
━━━ Phase 1: Foundation ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ? Install Docker (recommended for local image builds) [Y/n]
  ✔ Docker installed and started.
  → Installing k3s v1.29.4+k3s1 on master node...
  ✔ Control plane is Ready.

  ╔══════════════════════════════════════════════════╗
  ║  Worker Node Join Command                        ║
  ║  Run this on each worker node:                   ║
  ║  curl -fsSL https://get.k3s.io | \               ║
  ║    K3S_URL=https://192.168.1.100:6443 \           ║
  ║    K3S_TOKEN=K1075f3... \                         ║
  ║    sh -                                          ║
  ╚══════════════════════════════════════════════════╝

  ? Have you joined your 2 worker nodes? [y/N]

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

## Repo Structure

```
stackforge/
├── stackforge.sh                  # Main installer script
├── manifests/
│   ├── uptime-kuma/
│   │   └── uptime-kuma.yaml       # Deployment + PVC + NodePort svc
│   └── dashboard/
│       └── dashboard.yaml         # nginx pod + NodePort svc
├── dashboard/
│   └── index.html                 # Stackforge portal UI
├── docs/
│   └── ...                        # Tutorial companion (coming soon)
└── README.md
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

---

## After Install

**Change Grafana's default password** (admin / stackforge):

```bash
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o name) \
  -- grafana-cli admin reset-admin-password <newpassword>
```

**Check cluster health:**

```bash
kubectl get nodes
kubectl get pods -A
```

**Re-run to add more services:**

```bash
bash stackforge.sh
# Stackforge detects existing installs and skips them
```

---

## Philosophy

Stackforge is built around a few principles:

- **Guided, not scripted** — every decision is yours, explained in plain language
- **Lightweight first** — k3s over kubeadm, NodePort over LoadBalancer, single binary where possible
- **Idempotent** — safe to re-run, skips what's already installed
- **Cross-platform** — one script for every major Linux distro and architecture
- **Observable from minute one** — the dashboard is the first thing you see when it's done

---

## Companion Tutorial

Full write-up on ry-ops.dev: *coming soon*

Each phase of the installer maps to a blog post explaining why the decisions were made, not just what runs.

---

## Contributing

PRs welcome. Open issues for distro support requests, new tool additions, or bug reports.

---

## License

MIT © [ry-ops](https://github.com/ry-ops)
