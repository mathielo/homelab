# Homelab :house: :desktop_computer: :nerd_face: :lab_coat:

Docs, config, scripts and _whatnots_ for everything being set up and experimented with at my home lab.

# Docs

## General

- [Hardware, Network & Services](docs/README.md) — Hardware inventory, network architecture, service guides

## Ansible

- [Overview](ansible/README.md) — Host inventory and setup
- [Pi-hole](ansible/pihole.md) — Pi-hole + Unbound setup, Tailscale DNS
- [k3s Cluster](ansible/k3s.md) — k3s install, Tailscale, monitoring stack

## Tooling

- [MCP Server](mcp/README.md) — Claude Code MCP integration for Pi-hole and UniFi

# SSH: hosts, config & keys

All homelab related host configuration and SSH keys can be found in [`./config/ssh.config`](.config/ssh.config). They can be simply symlinked into `~/.ssh/config`:

```bash
# Write the public key from 1Passowrd to a file
op read "op://Private/GitHub 1P SSH/public key" > ~/.ssh/gh1p.pub

# Symlink the ssh config
ln -sf ~/src/homelab/.config/ssh.config ~/.ssh/config
```

# Workstation mounts

The UNAS shares are plain NFS entries in [`.config/etc.fstab`](.config/etc.fstab).

k3s-node-02's DAS array (`/mnt/r0`) is **not** exported, so it is reached over SSHFS
by [`.config/systemd/user/sshfs-node02-r0.service`](.config/systemd/user/sshfs-node02-r0.service),
which mounts it at `~/mnt/node02-r0` — the workstation has its own local `/mnt/r0`
and that path must stay free. It is a _user_ unit, not fstab: mount units run as
UID 0, and root can't authenticate against the 1Password agent socket that lives in
`$HOME`.

```bash
mkdir -p ~/.config/systemd/user
ln -sf ~/src/homelab/.config/systemd/user/sshfs-node02-r0.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now sshfs-node02-r0.service
```

UIDs match on both ends (`1000:1000`, `m8hl` owns the array), so the mount is
read/write with correct ownership. Throughput measured at ~35 MB/s — that is the
cross-VLAN wireless hairpin at the UDB Homelab, not SSHFS, so an NFS export would
not go any faster.

# Prerequisites

Some tools need to be installed locally to be able to manage the homelab setup, namely:

- Ansible
- sshpass
- Docker + compose plugin
- k9s
- age
- sops

Run the install script to set everything up in one shot:

```bash
./scripts/install.sh
```

Or install manually:

```bash
# Ansible + sshpass
sudo dnf install -y ansible sshpass

# Docker + compose plugin
sudo dnf config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER  # log out and back in after this

# k9s
sudo dnf install -y k9s

# age (encryption tool used by SOPS)
sudo dnf install -y age

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
