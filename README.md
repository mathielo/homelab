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

All homelab host configuration can be found in [`.config/ssh.config`](.config/ssh.config).
The main `~/.ssh/config` (1Password SSH agent, GitHub key) comes from
[mathielo/dotfiles](https://github.com/mathielo/dotfiles), and includes everything in
`~/.ssh/config.d/`. Link the homelab hosts there:

```bash
ln -sf ~/src/homelab/.config/ssh.config ~/.ssh/config.d/homelab
```

# Workstation mounts

All of them are in [`.config/etc.fstab`](.config/etc.fstab): NFS entries for the UNAS
shares and k3s-node-02's DAS array at `/mnt/n02r0`, plus the workstation's own local
RAID 0 at `/mnt/r0` (which is why the node's array cannot use that path). The NFS
entries need the workstation's VLAN 50 leg — see
[`workstation/README.md`](workstation/README.md#network).

```bash
sudo mkdir -p /mnt/nas/{backups,media,roms} /mnt/n02r0 /mnt/r0
# copy the entries into /etc/fstab, then
sudo systemctl daemon-reload
```

The DAS export is created by [`ansible/das-raid.yaml`](ansible/das-raid.yaml)
(`--tags nfs`) and carries the `mp` option, so it exists only while the array is
actually mounted on the node.

# Prerequisites

The workstation toolchain — Ansible, sshpass, kubectl, Helm, k9s, Argo CD CLI, age, sops,
mikefarah's yq, the GitHub CLI, the NFS client and Docker + compose — comes from the Arch
repos via the install script:

```bash
./scripts/install.sh
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
