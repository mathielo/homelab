# Homelab :house: :desktop_computer: :nerd_face: :lab_coat:

Docs, config, scripts and _whatnots_ for everything being set up and experimented with at my home lab.

# Docs

**Network**
- [Network & VLANs](network/README.md) — VLAN segmentation, WiFi SSIDs, DNS config, firewall rules

**Ansible**
- [Overview](ansible/README.md) — Host inventory and setup
- [Pi-hole](ansible/pihole.md) — Pi-hole + Unbound setup, Tailscale DNS
- [k3s Cluster](ansible/k3s.md) — k3s install, Tailscale, monitoring stack

**Services**
- [Ingress & DNS](services/ingress-dns.md) — How services are accessed (split-DNS, TLS, Cloudflare role)
- [Media Stack](services/media-stack.md) — ARR + Usenet services setup and configuration

**Tooling**
- [MCP Server](mcp/README.md) — Claude Code MCP integration for Pi-hole and UniFi

# Prerequisites

Some tools need to be installed locally to be able to manage the homelab setup, namely:
- Ansible
- sshpass
- Docker + compose plugin
- k9s
- age
- sops

```bash
# Ansible + sshpass
sudo add-apt-repository --yes ppa:ansible/ansible
sudo apt update
sudo apt install -y ansible software-properties-common sshpass

# Docker + compose plugin
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER  # log out and back in after this

# k9s
curl -sS https://webinstall.dev/k9s | bash

# age (encryption tool used by SOPS)
sudo apt install -y age

# sops (secret file encryption)
SOPS_VERSION=$(curl -s https://api.github.com/repos/getsops/sops/releases/latest | grep tag_name | cut -d '"' -f 4)
curl -LO "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
sudo install -m 755 "sops-${SOPS_VERSION}.linux.amd64" /usr/local/bin/sops
rm "sops-${SOPS_VERSION}.linux.amd64"

# Ansible community SOPS collection
ansible-galaxy collection install community.sops
```

# Secrets

Secrets (API tokens, passwords, credentials) are encrypted with [SOPS](https://github.com/getsops/sops) + [AGE](https://github.com/FiloSottile/age). Encrypted files follow the naming convention `*.sops.yaml` (or `.sops.json`, `.sops.env`).

See [.sops.yaml](./.sops.yaml) for instructions on how to manage AGE keys in this repository.

## Local setup (one-time)

Export `SOPS_AGE_KEY` to the environment:

```bash
# Loads the AGE private key from 1Password so SOPS can decrypt secrets
# without ever writing the key to disk.
#
# Update the op:// path to match your vault and item name.
# To find the correct path: op item get "<item-name>" --format json
export SOPS_AGE_KEY=$(op read "op://<vault>/<item>/AGE/secret key")
```
