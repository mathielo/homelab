#!/usr/bin/env bash
# Workstation bootstrap for managing this homelab from Fedora.
# Installs everything needed to drive Ansible playbooks, k3s, SOPS-encrypted
# secrets, and the YAML-driven scripts under scripts/. Idempotent — safe to
# re-run after Fedora upgrades or on a fresh workstation.

set -euo pipefail

# Docker repo
sudo dnf config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo

# All dnf packages
sudo dnf install -y \
    ansible sshpass \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    k9s \
    age

sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"

# sops (no Fedora package)
SOPS_VERSION=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | grep tag_name | cut -d '"' -f 4)
curl -fsSLO "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
sudo install -m 755 "sops-${SOPS_VERSION}.linux.amd64" /usr/local/bin/sops
rm "sops-${SOPS_VERSION}.linux.amd64"

# yq — mikefarah's Go yq, used by scripts/qbt/*.sh to parse YAML.
# Fedora's `yq` package is a different tool (Python jq-wrapper), so install from upstream.
YQ_VERSION=$(curl -fsSL https://api.github.com/repos/mikefarah/yq/releases/latest | grep tag_name | cut -d '"' -f 4)
curl -fsSLO "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
sudo install -m 755 yq_linux_amd64 /usr/local/bin/yq
rm yq_linux_amd64

# Ansible collection
ansible-galaxy collection install community.sops
