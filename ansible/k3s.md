# k3s Cluster

## Nodes

| Host       | Hardware                           | CPU            | RAM       | Storage        | IP         |
| ---------- | ---------------------------------- | -------------- | --------- | -------------- | ---------- |
| k3s-srv-01 | Lenovo ThinkCentre M715Q (2nd Gen) | Ryzen 3 2200GE | 32GB DDR4 | 256GB NVMe SSD | 10.10.50.3 |

## Namespaces

| Namespace      | Purpose                                          | Services                                                             |
| -------------- | ------------------------------------------------ | -------------------------------------------------------------------- |
| `kube-extra`   | Cluster infrastructure (monitoring, ingress)     | nginx-ingress, Prometheus, Grafana, Loki, Promtail                   |
| `media`        | Media stack (ARR + streaming, managed by ArgoCD) | Sonarr, Radarr, Prowlarr, Bazarr, SABnzbd, Plex, Jellyfin, Seerr   |
| `dashboard`    | User-facing dashboards and portals               | Homepage                                                             |
| `argocd`       | GitOps controller                                | ArgoCD                                                               |
| `cert-manager` | TLS certificate management                       | cert-manager                                                         |

## Prerequisites

1. Install **Ubuntu Server** on the target machine
   - During install, create user: `m8hl`
   - Enable OpenSSH server when prompted


## Bootstrap

The bootstrap playbook configures the server for remote management:
- Passwordless sudo for the `m8hl` user
- SSH public key authentication (only the key in the playbook is authorized)
- Password-based SSH disabled

First run (password auth still enabled, credentials loaded from secrets):

```bash
cd ansible
ansible-playbook bootstrap.yaml --limit k3s_servers
```

> :bulb: After bootstrap, SSH key auth is used for all subsequent playbooks.

> :warning: Once password SSH is disabled, losing your private key means you'll need physical/console access to recover. Keep a backup of your key.

## Tailscale

Installs Tailscale on the k3s node for private network access — no ports exposed to the internet.

### Prerequisites

Generate a reusable auth key at [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys) and add it to `ansible/group_vars/all/secrets.sops.yaml`.

### Deploy

```bash
ansible-playbook tailscale.yaml --limit k3s_servers
```

The playbook decrypts the secrets file, connects the node to your tailnet, and prints the node's Tailscale IP.

### Subnet routing

The Tailscale playbook advertises the Servers subnet (`10.10.50.0/24`) as a subnet route, allowing remote tailnet devices to reach k3s services at their LAN IPs.

After running the playbook, approve the route in the **Tailscale admin console** → Machines → k3s-srv-01 → Edit route settings → enable `10.10.50.0/24`.

### DNS setup (Pi-hole)

Pi-hole has a wildcard DNS record pointing `*.hl.mathielo.com` to the k3s LAN IP (`10.10.50.3`) via `/etc/dnsmasq.d/20-k3s.conf`. Combined with subnet routing, this resolves correctly for both LAN and tailnet devices.

## Install k3s

Installs k3s and sets up all cluster-level infrastructure:

```bash
ansible-playbook k3s/install-k3s.yaml
```

This will:
- Install k3s (Traefik disabled)
- Wait for the node to become Ready
- Install Helm
- Create the `kube-extra` namespace
- Deploy the nginx ingress controller into `kube-extra`
- Fetch the kubeconfig to `~/.kube/config-k3s` on your local machine

To use kubectl locally:

```bash
export KUBECONFIG=~/.kube/config-k3s
kubectl get nodes
```e

## Monitoring Stack

Deploys a lean observability stack into the `kube-extra` namespace:

| Component  | Chart                             | Role                                |
| ---------- | --------------------------------- | ----------------------------------- |
| Prometheus | `prometheus-community/prometheus` | Metrics collection and storage      |
| Grafana    | `grafana/grafana`                 | Dashboards for metrics and logs     |
| Loki       | `grafana/loki`                    | Log storage and query engine        |
| Promtail   | `grafana/promtail`                | Ships pod logs from nodes into Loki |

```bash
ansible-playbook k3s/monitoring.yaml
```

### Accessing Grafana

- **URL:** `https://grafana.hl.mathielo.com` (requires Tailscale + Pi-hole DNS, see above)
- **Username:** `admin`
- **Password:** set in `ansible/k3s/files/monitoring/grafana.values.yaml` (change before deploying or via the Grafana UI)

Both Prometheus and Loki datasources are pre-configured — no manual setup needed.

#### Recommended community dashboards to import

| Dashboard                   | ID      |
| --------------------------- | ------- |
| Node Exporter Full          | `1860`  |
| Kubernetes cluster overview | `6417`  |
| Loki log explorer           | `13639` |

### Configuration

Helm values live in `ansible/k3s/files/monitoring/`:

| File                     | Chart                                                  |
| ------------------------ | ------------------------------------------------------ |
| `prometheus.values.yaml` | Prometheus (server, node-exporter, kube-state-metrics) |
| `loki.values.yaml`       | Loki in SingleBinary mode                              |
| `promtail.values.yaml`   | Promtail DaemonSet                                     |
| `grafana.values.yaml`    | Grafana with pre-wired datasources and ingress         |

Key settings:
- **Retention:** 30 days for both Prometheus and Loki
- **Storage:** Persistent volumes via k3s local-path-provisioner (10Gi Prometheus, 10Gi Loki, 2Gi Grafana)
- **Resources:** Sized for a Mini PC/NUC

### Adding more services

ArgoCD-managed apps live in `k3s/apps/<namespace>/<app>/` as Helm charts (bjw-s/app-template v3). To add a new service:

1. Create `k3s/apps/<namespace>/<app>/Chart.yaml` and `values.yaml`
2. Add an ArgoCD Application CR in `k3s/argocd/apps/<app>.yaml` pointing to the chart
3. Commit and push — ArgoCD syncs automatically

The wildcard DNS record (`*.hl.mathielo.com → 10.10.50.3`) covers all subdomains, so no DNS changes needed for new `<app>.hl.mathielo.com` services. See existing apps in `k3s/apps/media/` for examples.
