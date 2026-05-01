# k3s Cluster

## Nodes

| Host        | Role   | IP          | Tailscale IP  |
| ----------- | ------ | ----------- | ------------- |
| k3s-server  | Server | 10.10.50.10 | 100.100.50.10 |
| k3s-node-01 | Agent  | 10.10.50.11 | 100.100.50.11 |

MetalLB VIP: `10.10.50.3` (ingress, DNS wildcard target)

> Full hardware specs: [docs/hardware.md](../docs/hardware.md)

## Prerequisites

1. Install **Ubuntu Server** on the target machine
   - During install, create user: `m8hl`
   - Enable OpenSSH server when prompted

## Namespaces

| Namespace         | Purpose                                          | Services                                                                                           |
| ----------------- | ------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| `kube-extra`      | Cluster infrastructure (monitoring, ingress)     | nginx-ingress, Prometheus, Grafana, Loki, Promtail                                                 |
| `metallb-system`  | Load balancer                                    | MetalLB (L2 mode, VIP 10.10.50.3)                                                                  |
| `media`           | Media stack (ARR + streaming, managed by ArgoCD) | Sonarr, Radarr, Prowlarr, Bazarr, SABnzbd, qBittorrent, Prismarr, Watchlistarr, Searcharr, AutoBrr |
| `dashboard`       | User-facing dashboards and portals               | Homepage, Uptime Kuma                                                                              |
| `argocd`          | GitOps controller                                | ArgoCD                                                                                             |
| `cert-manager`    | TLS certificate management                       | cert-manager                                                                                       |
| `longhorn-system` | Distributed k8s PVC storage                      | Longhorn detaches PVC from local nodes allowing for HA + pods moving freely between nodes          |

## Bootstrap

The bootstrap playbook configures the server for remote management:

- Passwordless sudo for the `m8hl` user
- SSH public key authentication (only the key in the playbook is authorized)
- Password-based SSH disabled

First run (password auth still enabled, credentials loaded from secrets):

```bash
cd ansible
ansible-playbook bootstrap.yaml --limit k3s_nodes
```

> :bulb: After bootstrap, SSH key auth is used for all subsequent playbooks.

> :warning: Once password SSH is disabled, losing your private key means you'll need physical/console access to recover. Keep a backup of your key.

## Tailscale

Installs Tailscale on the k3s node for private network access — no ports exposed to the internet. See [docs/tailscale.md](../docs/tailscale.md) for the overall architecture (IP convention, subnet routing, DNS flow).

### Prerequisites

Generate a reusable auth key at [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys) and add it to `ansible/group_vars/all/secrets.sops.yaml`.

### Deploy

```bash
ansible-playbook tailscale.yaml --limit k3s_server
```

The playbook decrypts the secrets file, connects the node to your tailnet, and prints the node's Tailscale IP.

### Subnet routing

The Tailscale playbook advertises the Servers subnet (`10.10.50.0/24`) as a subnet route from the **server node only**, allowing remote tailnet devices to reach k3s services at their LAN IPs.

After running the playbook, approve the route in the **Tailscale admin console** → Machines → k3s-server → Edit route settings → enable `10.10.50.0/24`.

### DNS setup (Pi-hole)

Pi-hole has a wildcard DNS record pointing `*.hl.mathielo.com` to the MetalLB VIP (`10.10.50.3`) via `/etc/dnsmasq.d/20-k3s.conf`. Combined with subnet routing, this resolves correctly for both LAN and tailnet devices.

## Install k3s

Installs k3s server and agents, and sets up cluster-level infrastructure:

```bash
# Install server + agents (run without --limit to set up the full cluster)
ansible-playbook k3s/install-k3s.yaml

# Install MetalLB load balancer
ansible-playbook k3s/metallb.yaml
```

The install playbook has two plays:

1. **Server** (`k3s_server` group): installs k3s server, Helm, nginx-ingress, fetches kubeconfig
2. **Agents** (`k3s_agents` group): joins agents to the cluster using the server's token

To use kubectl locally:

```bash
export KUBECONFIG=~/.kube/config-k3s
kubectl get nodes
```

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

ArgoCD-managed apps live in `k3s/apps/<namespace>/<app>/` as Helm charts (bjw-s/app-template v4). To add a new service:

1. Create `k3s/apps/<namespace>/<app>/Chart.yaml` and `values.yaml`
2. Add an ArgoCD Application CR in `k3s/argocd/apps/<app>.yaml` pointing to the chart
3. Commit and push — ArgoCD syncs automatically

The wildcard DNS record (`*.hl.mathielo.com → 10.10.50.3`, the MetalLB VIP) covers all subdomains, so no DNS changes needed for new `<app>.hl.mathielo.com` services. See existing apps in `k3s/apps/media/` for examples.
