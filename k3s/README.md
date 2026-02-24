# k3s Cluster

## Nodes

| Host         | Hardware                           | CPU            | RAM       | Storage        | IP           |
| ------------ | ---------------------------------- | -------------- | --------- | -------------- | ------------ |
| k3s-server-1 | Lenovo ThinkCentre M715Q (2nd Gen) | Ryzen 3 2200GE | 32GB DDR4 | 256GB NVMe SSD | 192.168.10.3 |

## Namespaces

| Namespace    | Purpose                                      |
| ------------ | -------------------------------------------- |
| `kube-extra` | Cluster infrastructure (monitoring, ingress) |
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

## Tailscale

Installs Tailscale on the k3s node for private network access — no ports exposed to the internet.

### Prerequisites

Generate a reusable auth key at [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys).

### Deploy

```bash
ansible-playbook 01-tailscale.yml
```

The playbook will prompt for the auth key, connect the node to your tailnet, and print the node's Tailscale IP.

### DNS setup (Pi-hole)

Add a wildcard DNS record in Pi-hole pointing `*.homelab` to the Tailscale IP printed by the playbook:

1. Pi-hole admin → **Local DNS → DNS Records**
2. Add record: `*.homelab` → `<tailscale-ip>`

All `*.homelab` hostnames will now resolve to the k3s node on any device in your tailnet.

## Install k3s

Installs k3s and sets up all cluster-level infrastructure:

```bash
ansible-playbook 02-install-k3s.yml
```

This will:
- Install k3s (Traefik disabled)
- Wait for the node to become Ready
- Install Helm
- Create the `kube-extra` and `prod` namespaces
- Deploy the nginx ingress controller into `kube-extra`
- Fetch the kubeconfig to `~/.kube/config-k3s` on your local machine

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
ansible-playbook 03-monitoring.yml
```

### Accessing Grafana

- **URL:** `http://grafana.homelab` (requires Tailscale + Pi-hole DNS record, see below)
- **Username:** `admin`
- **Password:** set in `ansible/files/monitoring/grafana-values.yml` (change before deploying or via the Grafana UI)

Both Prometheus and Loki datasources are pre-configured — no manual setup needed.

#### Recommended community dashboards to import

| Dashboard                  | ID     |
| -------------------------- | ------ |
| Node Exporter Full         | `1860` |
| Kubernetes cluster overview | `6417` |
| Loki log explorer          | `13639` |

### Configuration

Helm values live in `ansible/files/monitoring/`:

| File                    | Chart                                                  |
| ----------------------- | ------------------------------------------------------ |
| `prometheus-values.yml` | Prometheus (server, node-exporter, kube-state-metrics) |
| `loki-values.yml`       | Loki in SingleBinary mode                              |
| `promtail-values.yml`   | Promtail DaemonSet                                     |
| `grafana-values.yml`    | Grafana with pre-wired datasources and ingress         |

Key settings:
- **Retention:** 30 days for both Prometheus and Loki
- **Storage:** Persistent volumes via k3s local-path-provisioner (10Gi Prometheus, 10Gi Loki, 2Gi Grafana)
- **Resources:** Sized for a Mini PC/NUC

### Adding more services

To expose a new service at `myapp.homelab`, add an Ingress manifest in the `prod` namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: prod
spec:
  ingressClassName: nginx
  rules:
    - host: myapp.homelab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp
                port:
                  number: 80
```

No DNS changes needed — the wildcard record covers it automatically.
