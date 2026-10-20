#!/usr/bin/env bash
# Workstation bootstrap for managing this homelab from Arch Linux.
# Installs everything needed to drive Ansible playbooks, k3s, SOPS-encrypted
# secrets, the YAML-driven scripts under scripts/, and the workstation's NFS mounts.

set -euo pipefail

# go-yq is mikefarah's Go yq, used by scripts/qbt/*.sh to parse YAML. Arch's `yq`
# package is a different tool (Python jq-wrapper).
sudo pacman -S --needed \
    ansible sshpass \
    kubectl helm k9s argocd \
    age sops go-yq \
    github-cli nfs-utils \
    docker docker-compose docker-buildx

sudo systemctl enable --now docker

ansible-galaxy collection install community.sops
