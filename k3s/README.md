# k3s Cluster

## Nodes

| Host         | Hardware                           | CPU            | RAM       | Storage        | IP           |
| ------------ | ---------------------------------- | -------------- | --------- | -------------- | ------------ |
| k3s-server-1 | Lenovo ThinkCentre M715Q (2nd Gen) | Ryzen 3 2200GE | 32GB DDR4 | 256GB NVMe SSD | 192.168.10.3 |

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

Installs k3s in single-server mode with Traefik disabled:

```bash
ansible-playbook 01-install-k3s.yml
```

This will:
- Install k3s using the official install script
- Wait for the node to become Ready
- Fetch the kubeconfig to `~/.kube/config-k3s` on your local machine

To use kubectl locally:

```bash
export KUBECONFIG=~/.kube/config-k3s
kubectl get nodes
```

## Monitoring Stack

Deploys [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) (Prometheus, Grafana, Alertmanager) into the `monitoring` namespace:

```bash
ansible-playbook 02-monitoring.yml
```

This will:
- Install Helm on the k3s server
- Deploy the full kube-prometheus-stack via Helm
- Expose Grafana as a ClusterIP service (accessed via Cloudflare Tunnel)

### Accessing Grafana

- **URL:** `https://grafana.mathielo.com`
- **Username:** `admin`
- **Password:** `admin` (change on first login)

Grafana comes with pre-built dashboards for Kubernetes cluster metrics, node resources, and pod-level monitoring.

### Configuration

The Helm values are in `ansible/files/monitoring-values.yml`. Key settings:
- **Retention:** 7 days of Prometheus data
- **Storage:** Persistent volumes via k3s local-path-provisioner (10Gi Prometheus, 2Gi Grafana, 2Gi Alertmanager)
- **Resources:** Sized for a Mini PC/NUC

## Cloudflare Tunnel

Exposes k3s services as `*.mathielo.com` via [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — no open ports needed on the home network.

### Prerequisites

1. In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/), go to **Networks > Tunnels** and create a new tunnel
2. Base64-encode the tunnel token and set it in `ansible/files/cloudflared/secret.yml`
3. In the tunnel configuration on Cloudflare, add a public hostname:
   - **Subdomain:** `grafana` | **Domain:** `mathielo.com`
   - **Service:** `http://kube-prometheus-stack-grafana.monitoring:80`

### Deploy

```bash
ansible-playbook 03-cloudflared.yml
```

### Adding more services

To expose additional services, add more public hostnames in the Cloudflare tunnel configuration pointing to the in-cluster service (e.g., `http://service-name.namespace:port`). No changes to the cloudflared deployment are needed.

### Verification

1. `kubectl -n cloudflared get pods` — cloudflared pod should be Running
2. Cloudflare dashboard shows the tunnel as **Healthy**
3. `https://grafana.mathielo.com` loads Grafana
