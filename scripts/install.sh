#!/usr/bin/env bash
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

# Ansible collection
ansible-galaxy collection install community.sops
