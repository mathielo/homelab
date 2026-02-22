# k3s Cluster

## Nodes

| Host         | Hardware                           | CPU            | RAM       | Storage        | IP           |
| ------------ | ---------------------------------- | -------------- | --------- | -------------- | ------------ |
| k3s-server-1 | Lenovo ThinkCentre M715Q (2nd Gen) | Ryzen 3 2200GE | 32GB DDR4 | 256GB NVMe SSD | 192.168.10.3 |

## Namespaces

| Namespace   | Purpose                                      |
| ----------- | -------------------------------------------- |
| `kube-extra` | Cluster infrastructure (monitoring, tunnels) |
| `prod`       | Deployed services                            |

## Prerequisites

1. Install **Ubuntu Server** on the target machine
   - During install, create user: `k3s`
   - Enable OpenSSH server when prompted
2. Install Ansible and sshpass on your local machine:
   ```bash
   sudo add-apt-repository --yes --update ppa:ansible/ansible
   sudo apt install ansible sshpass
   ```

## Bootstrap

The bootstrap playbook configures the server for remote management:
- Passwordless sudo for the `k3s` user
- SSH public key authentication (only the key in the playbook is authorized)
- Password-based SSH disabled

First run (password auth still enabled):

```bash
cd k3s/ansible
ansible-playbook 00-bootstrap.yml --ask-pass --ask-become-pass
```

> :bulb: After bootstrap, password prompts are no longer needed.

> :warning: Once password SSH is disabled, losing your private key means you'll need physical/console access to recover. Keep a backup of your key.

## Install k3s

Installs k3s in single-server mode with Traefik disabled, then sets up cluster-level tooling:

```bash
ansible-playbook 01-install-k3s.yml
```

This will:
- Install k3s using the official install script
- Wait for the node to become Ready
- Install Helm
- Create the `kube-extra` and `prod` namespaces
- Fetch the kubeconfig to `~/.kube/config-k3s` on your local machine

To use kubectl locally:

```bash
export KUBECONFIG=~/.kube/config-k3s
kubectl get nodes
```

## Monitoring Stack

Deploys a lean observability stack into the `kube-extra` namespace:

| Component  | Chart                              | Role                                  |
| ---------- | ---------------------------------- | ------------------------------------- |
| Prometheus | `prometheus-community/prometheus`  | Metrics collection and storage        |
| Grafana    | `grafana/grafana`                  | Dashboards for metrics and logs       |
| Loki       | `grafana/loki`                     | Log storage and query engine          |
| Promtail   | `grafana/promtail`                 | Ships pod logs from nodes into Loki   |

```bash
ansible-playbook 02-monitoring.yml
```

### Accessing Grafana

- **URL:** `https://grafana.mathielo.com`
- **Username:** `admin`
- **Password:** set in `ansible/files/monitoring/grafana-values.yml` (change before deploying or via the Grafana UI)

Both Prometheus and Loki datasources are pre-configured — no manual setup needed.

#### Recommended community dashboards to import

| Dashboard | ID |
| --------- | -- |
| Node Exporter Full | `1860` |
| Kubernetes cluster overview | `6417` |
| Loki log explorer | `13639` |

### Configuration

Helm values live in `ansible/files/monitoring/`:

| File | Chart |
| ---- | ----- |
| `prometheus-values.yml` | Prometheus (server, node-exporter, kube-state-metrics) |
| `loki-values.yml` | Loki in SingleBinary mode |
| `promtail-values.yml` | Promtail DaemonSet |
| `grafana-values.yml` | Grafana with pre-wired datasources |

Key settings:
- **Retention:** 30 days for both Prometheus and Loki
- **Storage:** Persistent volumes via k3s local-path-provisioner (10Gi Prometheus, 10Gi Loki, 2Gi Grafana)
- **Resources:** Sized for a Mini PC/NUC

## Cloudflare Tunnel

Exposes k3s services as `*.mathielo.com` via [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — no open ports needed on the home network.

### Prerequisites

1. In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/), go to **Networks > Tunnels** and create a new tunnel
2. Copy the tunnel token (the playbook will prompt for it at runtime)
3. In the tunnel configuration on Cloudflare, add a public hostname for each service to expose:
   - **Subdomain:** `grafana` | **Domain:** `mathielo.com`
   - **Service:** `http://grafana.kube-extra:80`

### Deploy

```bash
ansible-playbook 03-cloudflared.yml
```

### Adding more services

To expose additional services, add more public hostnames in the Cloudflare tunnel configuration pointing to the in-cluster service (e.g., `http://service-name.namespace:port`). No changes to the cloudflared deployment are needed.

### Verification

1. `kubectl -n kube-extra get pods` — cloudflared pod should be Running
2. Cloudflare dashboard shows the tunnel as **Healthy**
3. `https://grafana.mathielo.com` loads Grafana
