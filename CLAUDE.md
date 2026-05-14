# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a homelab repository for documenting, configuring, and automating a home network infrastructure. The setup uses **Ubiquiti UniFi** devices exclusively for all networking equipment.

## Working Style

- **Ask before assuming**: When requirements are ambiguous or unclear, ask clarifying questions before starting work. It's better to clarify upfront than waste effort on incorrect assumptions.
- **Target environment**: Linux (Pop_OS!) unless otherwise specified.
- **User context**: Seasoned developer comfortable with code, learning networking specifics and advanced features.
- **No git operations**: Do not commit, push, or perform other git operations unless explicitly asked. The user prefers to review all changes and commit themselves.

## Security (Public Repository)

This repository is **public**. When making changes:

- **Never commit plaintext secrets** — all credentials must go through SOPS/AGE encryption (`*.sops.yaml`). If you see plaintext passwords, API keys, tokens, or private keys being added to tracked files, flag it immediately.
- **Verify `.gitignore` coverage** — before creating files that could contain secrets (`.env`, `*.key`, `kubeconfig`, etc.), confirm they are gitignored.
- **Audit new templates** — Jinja2 templates (`.j2`) should use `{{ variable }}` references, never hardcoded secret values.
- **Sensitive operations** — use `no_log: true` in Ansible tasks that handle secrets.
- **Internal details are acceptable** — private IPs, VLAN layout, domain names, and public keys are fine to include; they are non-exploitable without network access.

## Domain

- **Domain:** `mathielo.com` (managed in Cloudflare)
- **Homelab services:** accessible as `*.hl.mathielo.com` via split-DNS (Pi-hole + k3s ingress, no public exposure)

## Repository Structure

- `docs/` - Hardware inventory, network architecture, service guides
- `k3s/` - Kubernetes cluster setup, manifests, and Ansible playbooks

## Runbooks

- **PVC operations** (scaling apps down/up, stopping pods, restoring from Longhorn backup or host tarball) → read [`docs/pvc-maintenance.md`](docs/pvc-maintenance.md) first. PVCs and Deployments are owned by different Argo apps (`*-infra` vs per-service) and the root `media-apps` reconciles patches — naive `kubectl scale` or `selfHeal: false` will get reverted.

## Network Architecture

Router: R18 UGC Max (UniFi)

Scheme: `10.10.<VLAN_ID>.x` — VLAN ID doubles as the subnet's third octet.

| VLAN | Subnet         | Hosts | IPv6                     | Purpose               |
| ---- | -------------- | ----- | ------------------------ | --------------------- |
| 1    | 10.10.1.0/24   | 254   | 2001:2042:37b0:1c00::/64 | UniFi management      |
| 10   | 10.10.10.0/24  | 254   | 2001:2042:37b0:1c02::/64 | Trusted (PCs, phones) |
| 40   | 10.10.40.0/24  | 254   | -                        | Guest                 |
| 50   | 10.10.50.0/24  | 254   | -                        | Servers (k3s)         |
| 53   | 10.10.53.0/24  | 254   | 2001:2042:37b0:1c35::/64 | DNS (Pi-hole)         |
| 107  | 10.10.107.0/24 | 254   | -                        | IoT (lights, sensors) |

- Gateway at .1 in each VLAN (e.g. `10.10.10.1` for VLAN 10)
- Only Trusted (VLAN 10) can access Servers + IoT; all others isolated
- All VLANs can reach Pi-hole (`10.10.53.53`) on port 53 for DNS
- Guest, Servers, DNS, and IoT have no IPv6 (simpler, more secure)
- DNS fallback: Quad9 (9.9.9.9, 149.112.112.112)

## Current Services

- **Pi-hole v6** on Raspberry Pi 5: Network-wide DNS resolver for ad/malware blocking (`10.10.53.53` / `100.100.53.53` on Tailscale)
  - Config: `/etc/pihole/pihole.toml` (v6 uses TOML, not the legacy dnsmasq conf files)
  - v6 ignores `/etc/dnsmasq.d/` by default (`misc.etc_dnsmasq_d = false`) — must be explicitly enabled
  - DNS service: `pihole-FTL` (restart with `sudo systemctl restart pihole-FTL`)
  - **Unbound** runs as recursive resolver on `127.0.0.1:5335`; Pi-hole uses it as upstream instead of Quad9 directly
  - DNS chain: Device → Pi-hole (`:53`) → Unbound (`127.0.0.1:5335`) → root nameservers
- **UNAS-4** (UniFi NAS): Network-attached storage on VLAN 1 (`10.10.1.4`)
  - 4×24 TB 7200RPM HDD in RAID 5 (~72 TB usable) + 2×500 GB M.2 SSD read-write cache
  - NFS share `Media` (52 TB quota) exported to k3s nodes at `/var/nfs/shared/Media`
  - NFS share `Backups` exported to k3s nodes at `/var/nfs/shared/Backups`
  - NFS share `k3s` exported to k3s nodes at `/var/nfs/shared/k3s` — dedicated Longhorn backup target
  - `media-data` PVC mounts the full `Media` share; `dl/` and `lib/` are top-level subdirs — same mount enables hardlinks between download clients and ARR library moves
- **k3s cluster**: Multi-node Kubernetes (server + agent) running Prometheus, Grafana, Loki, Promtail
  - Server: `k3s-server` (M75q-1) at `10.10.50.10`
  - Agent: `k3s-node-01` (M715Q) at `10.10.50.11`
  - MetalLB VIP: `10.10.50.3` (ingress target, DNS wildcard destination)
- **Cloudflare (DNS-01 only)**: Cloudflare manages the `mathielo.com` domain and provides DNS-01 challenge validation for Let's Encrypt certificates via cert-manager. No Cloudflare Tunnel — no services are publicly exposed.
- **Tailscale**: Private overlay network for remote access to k3s services and Pi-hole
  - Tailnet: `qilin-goby.ts.net`
  - k3s server: `100.100.50.10` (mirrors local `10.10.50.10`)
  - Pi-hole: `100.100.53.53` (mirrors local `10.10.53.53`)
  - Pi-hole wildcard record: `*.hl.mathielo.com → 10.10.50.3` (MetalLB VIP, via `/etc/dnsmasq.d/20-k3s.conf`)
  - k3s server advertises `10.10.50.0/24` as a Tailscale subnet route so remote tailnet devices can reach LAN IPs

## MCP Access Policy

Claude has MCP access to Pi-hole and UniFi for **read-only purposes**:

- **DO NOT** make any changes directly to Pi-hole or UniFi
- **DO** query and display current configurations, rules, clients, etc.
- **DO** provide guidance and commands/steps for the user to apply changes manually
- The user wants to learn by applying changes themselves

## Versioning Policy

- **Always use the latest stable version** when adding new dependencies (Helm charts, container images, tools).
- **Pin explicit versions** — never use `latest`, `stable`, or floating tags. Renovate tracks updates via pinned versions.
- **Renovate** (GitHub App) monitors all dependencies and opens PRs for updates on weekends.
- **Check Renovate config** — when adding any versioned dependency (Helm chart, container image, pip/uv package, etc.), verify that `renovate.json5` has a matching custom manager regex if the file/format isn't auto-detected. Add one if missing.
- Look up current latest versions online before implementing — don't assume versions from memory or documentation are current.

## Planned Expansions

- Backup solutions
- VPN (Wireguard or UniFi Teleport)
