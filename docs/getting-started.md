# Getting Started with Stackforge

This guide walks you through everything after `bash stackforge.sh` finishes — setting up monitoring, adding nodes, and configuring Uptime Kuma.

---

## Table of Contents

- [Accessing Your Cluster](#accessing-your-cluster)
- [Setting Up Uptime Kuma](#setting-up-uptime-kuma)
- [Adding Monitors to Uptime Kuma](#adding-monitors-to-uptime-kuma)
- [Adding Worker Nodes](#adding-worker-nodes)
- [Adding Custom Services to the Dashboard](#adding-custom-services-to-the-dashboard)
- [Monitoring External Devices](#monitoring-external-devices)
- [Common kubectl Commands](#common-kubectl-commands)

---

## Accessing Your Cluster

Stackforge never touches `~/.kube/config`. Use the dedicated kubeconfig:

```bash
# One-off command
KUBECONFIG=~/.stackforge/kubeconfig kubectl get nodes

# Create an alias (add to ~/.bashrc or ~/.zshrc)
alias sfk='KUBECONFIG=~/.stackforge/kubeconfig kubectl'

# Then use it like normal kubectl
sfk get pods -A
sfk get nodes -o wide
```

---

## Setting Up Uptime Kuma

Uptime Kuma is your service health monitoring dashboard. On first visit, you need to create an admin account.

### 1. Open Uptime Kuma

Navigate to **http://localhost:32100** (or your node IP on bare-metal).

### 2. Create Admin Account

You'll see the setup wizard:

- **Username:** Choose a username (e.g., `admin`)
- **Password:** Must be a strong password (uppercase, lowercase, number, special character — e.g., `MyHomeLab2024!`)
- Click **Create**

### 3. You're in

You'll land on an empty dashboard. Now add monitors for your services.

---

## Adding Monitors to Uptime Kuma

Uptime Kuma monitors your services and alerts you when something goes down. Here are the recommended monitors for your stackforge cluster.

### Quick Setup: Add All Stackforge Services

For each service below, click **+ Add New Monitor** in Uptime Kuma and fill in the fields:

| Monitor Name | Type | URL / Host | Interval |
|---|---|---|---|
| Stackforge Dashboard | HTTP(s) | `http://localhost:30080` | 30s |
| Grafana | HTTP(s) | `http://localhost:32000/api/health` | 30s |
| Prometheus | HTTP(s) | `http://localhost:32001/-/healthy` | 30s |
| Traefik Dashboard | HTTP(s) | `http://localhost:32090/dashboard/` | 30s |
| Portainer | HTTP(s) | `https://localhost:30779` | 30s |
| Uptime Kuma (self) | HTTP(s) | `http://localhost:32100` | 60s |

> **Bare-metal users:** Replace `localhost` with your master node's IP address.

> **Portainer note:** Enable "Ignore TLS/SSL errors" since Portainer uses a self-signed certificate.

### Step-by-Step: Adding a Monitor

1. Click **+ Add New Monitor** (top left)
2. **Monitor Type:** Select `HTTP(s)`
3. **Friendly Name:** e.g., `Grafana`
4. **URL:** Paste the URL from the table above
5. **Heartbeat Interval:** `30` seconds (or your preference)
6. Leave other settings as defaults
7. Click **Save**

The monitor will start pinging immediately. A green bar means the service is healthy.

### Adding a TCP Port Monitor

For services that don't have an HTTP endpoint, use TCP monitoring:

1. **Monitor Type:** Select `TCP Port`
2. **Hostname:** Your node IP or `localhost`
3. **Port:** The service port number

### Monitoring Kubernetes Nodes

To monitor that your k3s nodes are reachable:

| Monitor Name | Type | Host | Port |
|---|---|---|---|
| k3s Master | TCP Port | `<master-ip>` | 6443 |
| k3s Worker 1 | TCP Port | `<worker-ip>` | 10250 |
| k3s Worker 2 | TCP Port | `<worker-ip>` | 10250 |

- **Port 6443** is the Kubernetes API server (master node)
- **Port 10250** is the kubelet (any node)

---

## Adding Worker Nodes

### Docker Desktop (k3d)

k3d clusters run entirely inside Docker. To add worker nodes:

```bash
# Add a worker node to the existing cluster
k3d node create stackforge-worker-1 --cluster stackforge --role agent

# Verify
KUBECONFIG=~/.stackforge/kubeconfig kubectl get nodes
```

### Bare-Metal

On your **master node**, generate a join token:

```bash
bash stackforge.sh --worker
```

This prints a `k3s agent` join command. Run that command on each worker machine:

```bash
# On the worker machine:
curl -sfL https://get.k3s.io | K3S_URL=https://<master-ip>:6443 K3S_TOKEN=<token> sh -
```

Replace `<master-ip>` with your master node's IP and `<token>` with the token from the master.

#### Verifying Workers Joined

```bash
# On the master node
KUBECONFIG=~/.stackforge/kubeconfig kubectl get nodes

# Expected output:
# NAME         STATUS   ROLES                  AGE   VERSION
# sf-master    Ready    control-plane,master   1h    v1.30.x+k3s1
# sf-worker1   Ready    <none>                 5m    v1.30.x+k3s1
# sf-worker2   Ready    <none>                 3m    v1.30.x+k3s1
```

#### Removing a Worker Node

```bash
# On the master — drain the node first
KUBECONFIG=~/.stackforge/kubeconfig kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Then delete it
KUBECONFIG=~/.stackforge/kubeconfig kubectl delete node <node-name>

# On the worker machine — uninstall k3s agent
/usr/local/bin/k3s-agent-uninstall.sh
```

---

## Adding Custom Services to the Dashboard

The Stackforge dashboard supports adding your own service cards.

### From the Dashboard UI

1. Open the dashboard at **http://localhost:30080**
2. Scroll to the bottom of the service grid
3. Click the **+ ADD** button
4. Fill in:
   - **Name:** Your service name
   - **URL:** The full URL (e.g., `http://192.168.1.50:8080`)
   - **Description:** A short note about the service
5. Click **Save**

Custom services are saved in your browser's localStorage and persist across refreshes.

### Examples of Services to Add

| Name | URL | Description |
|---|---|---|
| Pi-hole | `http://192.168.1.10/admin` | DNS Ad Blocker |
| Home Assistant | `http://192.168.1.20:8123` | Smart Home |
| Plex | `http://192.168.1.30:32400/web` | Media Server |
| NAS | `http://192.168.1.40:5000` | Synology / TrueNAS |
| Router | `http://192.168.1.1` | Network Gateway |

---

## Monitoring External Devices

You can monitor devices beyond your Kubernetes cluster using Uptime Kuma.

### Network Devices (Ping)

1. In Uptime Kuma, click **+ Add New Monitor**
2. **Monitor Type:** `Ping`
3. **Hostname:** IP address of the device (e.g., `192.168.1.1`)
4. **Friendly Name:** e.g., `Router`, `NAS`, `Printer`

### Docker Containers (on other hosts)

If you run Docker containers outside your k3s cluster:

1. **Monitor Type:** `HTTP(s)` or `TCP Port`
2. **URL/Host:** The host IP and exposed port
3. Example: `http://192.168.1.50:8080` for a container exposing port 8080

### Home Network Devices

| Device | Monitor Type | Host / URL | Notes |
|---|---|---|---|
| Router | Ping | `192.168.1.1` | Gateway health |
| NAS | HTTP(s) | `http://192.168.1.40:5000` | Web UI check |
| Printer | Ping | `192.168.1.100` | Network printer |
| Smart Hub | HTTP(s) | `http://192.168.1.20:8123` | Home Assistant |
| Pi-hole | HTTP(s) | `http://192.168.1.10/admin` | DNS server |

### Setting Up Notifications

Uptime Kuma supports notifications when services go down:

1. Go to **Settings** (gear icon) > **Notifications**
2. Click **Setup Notification**
3. Choose your provider:
   - **Discord** — Paste a webhook URL
   - **Slack** — Paste a webhook URL
   - **Email (SMTP)** — Configure your mail server
   - **Telegram** — Bot token + chat ID
   - **Pushover, Gotify, ntfy** — For mobile push notifications
4. Test the notification, then **Save**
5. When adding monitors, check **Enable Notification** and select your notification method

---

## Common kubectl Commands

All commands use the stackforge kubeconfig. Use the alias `sfk` (see [Accessing Your Cluster](#accessing-your-cluster)).

```bash
# Cluster overview
sfk get nodes -o wide              # Node status, IPs, versions
sfk top nodes                      # CPU and memory usage per node
sfk get pods -A                    # All pods across all namespaces

# Service health
sfk get pods -n monitoring          # Grafana, Prometheus, Uptime Kuma
sfk get pods -n traefik             # Traefik ingress
sfk get pods -n portainer           # Portainer
sfk get pods -n stackforge          # Dashboard + sf-api sidecar

# Debugging
sfk logs -n stackforge deploy/stackforge-dashboard -c sf-api    # API logs
sfk logs -n monitoring deploy/uptime-kuma                       # Uptime Kuma logs
sfk describe pod <pod-name> -n <namespace>                      # Pod details
sfk get events -A --sort-by='.lastTimestamp' | tail -20          # Recent events

# Restart a service
sfk rollout restart deploy/<name> -n <namespace>

# Resource usage
sfk top pods -A --sort-by=memory    # Pods sorted by memory
sfk top pods -A --sort-by=cpu       # Pods sorted by CPU
```

---

## Default Ports

| Service | Port | Protocol |
|---|---|---|
| Stackforge Dashboard | 30080 | HTTP |
| Portainer | 30777 / 30779 | HTTP / HTTPS |
| Traefik HTTP | 32080 | HTTP |
| Traefik HTTPS | 32443 | HTTPS |
| Traefik Dashboard | 32090 | HTTP |
| Grafana | 32000 | HTTP |
| Prometheus | 32001 | HTTP |
| Uptime Kuma | 32100 | HTTP |

---

## Default Credentials

| Service | Username | Password | Notes |
|---|---|---|---|
| Grafana | `admin` | Random (shown at install) | Stored in `~/.stackforge/state.env` |
| Portainer | `admin` | Random (shown at install) | Stored in `~/.stackforge/state.env` |
| Uptime Kuma | — | — | Set up on first visit |

---

## Managing Credentials

Stackforge generates random passwords for Grafana and Portainer during install. They're stored in a Kubernetes Secret (`stackforge-credentials`) and in `~/.stackforge/state.env`.

### Viewing Passwords

```bash
cat ~/.stackforge/state.env
```

### Changing Passwords via Dashboard

1. Open the Stackforge Dashboard at **http://localhost:30080**
2. Scroll to the **CREDENTIALS** section
3. Click **CHANGE** next to the service
4. Enter your current password and new password
5. Click **CONFIRM**

The password is updated in both the Kubernetes Secret and the service itself.

### Resetting All Passwords

If you've lost access or want to regenerate all passwords:

```bash
bash stackforge.sh --reset-passwords
```

This generates new random passwords, updates the Kubernetes Secret, syncs with each service's API, and saves the new credentials to `~/.stackforge/state.env`.

---

## Next Steps

- Set up [Grafana dashboards](http://localhost:32000) for detailed metrics visualization
- Configure [Traefik IngressRoutes](http://localhost:32090/dashboard/) for custom routing
- Explore the [Stackforge Dashboard](http://localhost:30080) for real-time cluster monitoring
- Add your homelab devices to Uptime Kuma for full network visibility
