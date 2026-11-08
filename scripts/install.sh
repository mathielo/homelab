#!/usr/bin/env bash
# Workstation bootstrap for managing this homelab from Arch Linux. Run it after the
# dotfiles install, from a clone at ~/src/homelab. Safe to re-run.
# Installs everything needed to drive Ansible playbooks, k3s, SOPS-encrypted secrets and
# the YAML-driven scripts under scripts/, then sets up the workstation's SSH hosts, shell
# additions and mounts.

set -euo pipefail

# go-yq is mikefarah's Go yq, used by scripts/qbt/*.sh to parse YAML. Arch's `yq`
# package is a different tool (Python jq-wrapper).
sudo pacman -S --needed \
    ansible sshpass \
    kubectl helm k9s argocd \
    age sops go-yq \
    github-cli nfs-utils \
    mdadm xfsprogs \
    docker docker-compose docker-buildx

sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"

ansible-galaxy collection install community.sops

mkdir -p -m 700 ~/.ssh/config.d
ln -sf ~/src/homelab/.config/ssh.config ~/.ssh/config.d/homelab

# Deleting the line first keeps it from piling up across runs.
sed -i '\|src/homelab/.config/bashrc|d' ~/.bashrc
echo 'source "$HOME/src/homelab/.config/bashrc"' >> ~/.bashrc

# Everything from "# UNAS" to the end of /etc/fstab comes from .config/etc.fstab.
sudo mkdir -p /mnt/nas/{backups,media,roms} /mnt/n02r0 /mnt/r0
sudo sed -i '/^# UNAS$/,$d' /etc/fstab
sudo tee -a /etc/fstab < ~/src/homelab/.config/etc.fstab > /dev/null
sudo systemctl daemon-reload

echo "Next: gh auth login, the VLAN playbook (workstation/README.md), then reboot."
