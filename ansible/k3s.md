# k3s Cluster

## Nodes

| Host        | Role   | IP          | Tailscale IP  |
| ----------- | ------ | ----------- | ------------- |
| k3s-server  | Server | 10.10.50.10 | 100.100.50.10 |
| k3s-node-01 | Agent  | 10.10.50.11 | 100.100.50.11 |
| k3s-node-02 | Agent  | 10.10.50.12 | 100.100.50.12 |

MetalLB VIP: `10.10.50.3` (ingress, DNS wildcard target)

> Full hardware specs: [docs/hardware.md](../docs/hardware.md)

## Prerequisites

1. Install **Ubuntu Server** on the target machine
   - During install, create user: `m8hl`
   - Enable OpenSSH server when prompted

## Namespaces

| Namespace         | Purpose                                          | Services                                                                                                                |
| ----------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| `kube-extra`      | Cluster ingress                                  | nginx-ingress                                                                                                           |
| `monitoring`      | Observability stack (managed by ArgoCD)          | Prometheus, Alertmanager, Grafana, Loki, Promtail                                                                       |
| `metallb-system`  | Load balancer                                    | MetalLB (L2 mode, VIP 10.10.50.3)                                                                                       |
| `media`           | Media stack (ARR + streaming, managed by ArgoCD) | Plex, Sonarr, Radarr, Prowlarr, Bazarr, Profilarr, SABnzbd, qBt-{se,br,mam}, qui, Prismarr, Pulsarr, Searcharr, AutoBrr |
| `dashboard`       | User-facing dashboards and portals               | Homepage, Uptime Kuma, Kiosk, Yata                                                                                      |
| `tools`           | Misc self-hosted apps (managed by ArgoCD)        | SearXNG, Miniflux                                                                                                       |
| `argocd`          | GitOps controller                                | ArgoCD                                                                                                                  |
| `cert-manager`    | TLS certificate management                       | cert-manager                                                                                                            |
| `longhorn-system` | Distributed k8s PVC storage                      | Longhorn detaches PVC from local nodes allowing for HA + pods moving freely between nodes                               |

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

Pi-hole has a wildcard DNS record pointing `*.m6o.dev` to the MetalLB VIP (`10.10.50.3`) via `/etc/dnsmasq.d/20-k3s.conf`. Combined with subnet routing, this resolves correctly for both LAN and tailnet devices.

## Install k3s

Installs k3s server and agents, and sets up cluster-level infrastructure:

```bash
cd ansible

# Install server + agents
ansible-playbook k3s/install-k3s.yaml

# Install MetalLB load balancer — required for ingress-nginx LoadBalancer Service
# to get a real IP. install-k3s.yaml deploys ingress-nginx but no longer waits
# on the LoadBalancer; MetalLB assigns the VIP (10.10.50.3) once installed.
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

## Host I/O tuning

Applies kernel, udev, and mount tunings to keep slow remote I/O (NFS to UNAS-4) from cascading into node-wide stalls, and to deepen block-layer queues on the IOPS-limited Kingston SSD in `k3s-node-01`.

```bash
ansible-playbook host-tuning.yaml
```

Idempotent — safe to re-run. See [docs/storage-tuning.md](../docs/storage-tuning.md) for what gets applied and why.

## Monitoring Stack

A lean observability stack runs in the `monitoring` namespace, deployed by
**ArgoCD** from `k3s/apps/monitoring/` — one umbrella chart per component:

| Component  | Chart                             | Role                                |
| ---------- | --------------------------------- | ----------------------------------- |
| Prometheus | `prometheus-community/prometheus` | Metrics + Alertmanager (Telegram)   |
| Grafana    | `grafana/grafana`                 | Dashboards for metrics and logs     |
| Loki       | `grafana/loki`                    | Log storage and query engine        |
| Promtail   | `grafana/promtail`                | Ships pod logs from nodes into Loki |

All PVCs are on Longhorn, so the pods reschedule freely across nodes.

### Accessing Grafana

- **URL:** `https://grafana.m6o.dev` (requires Tailscale + Pi-hole DNS, see above)

Both Prometheus and Loki datasources are pre-configured — no manual setup needed.

#### Recommended community dashboards to import

| Dashboard                   | ID      |
| --------------------------- | ------- |
| Node Exporter Full          | `1860`  |
| Kubernetes cluster overview | `6417`  |
| Loki log explorer           | `13639` |

### Configuration

Helm values live beside each chart in `k3s/apps/monitoring/<component>/values.yaml`
(`prometheus`, `loki`, `promtail`, `grafana`). Secrets are in per-component
`values.sops.yaml` (Grafana admin, Alertmanager Telegram token), decrypted by
ArgoCD's helm-secrets plugin.

Key settings:

- **Retention:** 30 days for both Prometheus and Loki
- **Storage:** Longhorn PVCs (10Gi Prometheus, 10Gi Loki, 2Gi Grafana, 1Gi Alertmanager)
- **Resources:** Sized for a Mini PC/NUC
- **Alerting:** Alertmanager → Telegram; rules in `prometheus/values.yaml` under `serverFiles.alerting_rules.yml`

### Adding more services

ArgoCD-managed apps live in `k3s/apps/<namespace>/<app>/` as Helm charts (bjw-s/app-template v4). To add a new service:

1. Create `k3s/apps/<namespace>/<app>/Chart.yaml` and `values.yaml`
2. Add an ArgoCD Application CR in `k3s/argocd/apps/<app>.yaml` pointing to the chart
3. Commit and push — ArgoCD syncs automatically

The wildcard DNS record (`*.m6o.dev → 10.10.50.3`, the MetalLB VIP) covers all subdomains, so no DNS changes needed for new `<app>.m6o.dev` services. See existing apps in `k3s/apps/media/` for examples.
