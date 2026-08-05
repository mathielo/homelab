# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a homelab repository for documenting, configuring, and automating a home network infrastructure. The setup uses **Ubiquiti UniFi** devices exclusively for all networking equipment.

## Working Style

- **Ask before assuming**: When _requirements_ are ambiguous, ask clarifying questions before starting. But for facts about the _existing setup_, read the repo's config/manifests/docs directly — the repo is the source of truth, don't ask what you can look up.
- **Target environment**: Commands run from a Fedora Linux workstation; k3s nodes run Ubuntu Server. Assume this unless otherwise specified.
- **User context**: Seasoned developer comfortable with code, learning networking specifics and advanced features.
- **No git operations**: Do not commit, push, or perform other git operations unless explicitly asked. The user reviews and commits all changes themselves.
- **Scripts stay simple**: Flat, sequential commands. No logging helpers, no idempotency/exists guards inside scripts — readability over cleverness (idempotency belongs in the Ansible/GitOps layer, not shell scripts).
- **Planning docs live in the repo**: Commit planning/runbook docs under the repo (e.g. `docs/` or `plans/`), never in a workstation-only local path.
- **Keep docs in sync**: The repo is the source of truth, so it must stay accurate. Whenever you spot an outdated/stale doc while doing any task (removed service still listed, renamed path, changed port, etc.), fix it as part of that task. If the fix is genuinely out of scope, flag it explicitly rather than ignore it. Never trust a doc over the live config/manifests — verify, then correct the doc.

## Infrastructure Changes (IaC Only)

Everything is GitOps: tracked in code, idempotent, replayable. **Never mutate live infrastructure directly** — this generalizes the MCP read-only policy below to _all_ infrastructure.

- **No mutating commands**: no `kubectl apply/edit/patch/scale`, no `helm upgrade/install`, no direct file/sysctl edits on nodes, no write calls to the qBittorrent / Pi-hole / UniFi APIs. Propose every change as code (Ansible, Helm values, k8s manifests) and hand the user the exact command to run. Read-only inspection (`kubectl get`, SSH `vmstat`/`cat /proc/...`) is fine.
- **Prefer**: ConfigMaps over PVCs for config, Ansible over manual steps, checked-in manifests over imperative `kubectl`.
- **kubectl/helm run locally**: the workstation kubeconfig talks to the cluster — run them directly, never SSH-wrapped. Use bare `kubectl` (no `sudo`, no `KUBECONFIG=` override). SSH to nodes only for read-only OS inspection.
- **Ansible playbooks** (k3s, cert-manager, argocd) run from the repo root with `-i ansible/inventory.ini`. (Monitoring is GitOps now — deployed by ArgoCD from `k3s/apps/monitoring/`, not Ansible.)
- **Ad-hoc Longhorn snapshots/backups** via the Longhorn UI, not `kubectl` Snapshot/Backup CRs (Argo ownership/reconciliation fights CR-based ones).

## Security (Public Repository)

This repository is **public**. When making changes:

- **Never commit plaintext secrets** — all credentials must go through SOPS/AGE encryption (`*.sops.yaml`). If you see plaintext passwords, API keys, tokens, or private keys being added to tracked files, flag it immediately.
- **Verify `.gitignore` coverage** — before creating files that could contain secrets (`.env`, `*.key`, `kubeconfig`, etc.), confirm they are gitignored.
- **Audit new templates** — Jinja2 templates (`.j2`) should use `{{ variable }}` references, never hardcoded secret values.
- **Sensitive operations** — use `no_log: true` in Ansible tasks that handle secrets.
- **Internal details are acceptable** — private IPs, VLAN layout, domain names, and public keys are fine to include; they are non-exploitable without network access.
- **SOPS workflow** — never run `sops -d` or decrypt secrets; the user handles all decryption with their own AGE key (not in the repo). Do not create, populate, or encrypt `*.sops.yaml` files: build everything else (Chart, values, ArgoCD app), then tell the user exactly which sops file to create and which keys it must contain.
- **No redundant filename prefixes** — don't prefix what the extension/convention already conveys: `argocd.sops.yaml`, not `secrets-argocd.sops.yaml`.

## Domain

- **Domain:** `m6o.dev` (managed in Cloudflare) — shared between a public website and the homelab
- **Homelab services:** `*.m6o.dev` via split-DNS wildcard (Pi-hole + k3s ingress, no public exposure) — new services need no DNS change
- **Public names:** the apex `m6o.dev` (website) resolves via normal public DNS. The Pi-hole wildcard is written `address=/*.m6o.dev/...` — the leading `*.` is what keeps the apex out of it, and must never be dropped (`/m6o.dev/` and `/.m6o.dev/` both swallow the apex, with no way to hand it back). A public **subdomain** like `r2.m6o.dev` needs one `server=/<name>.m6o.dev/#` exclusion line. See [`docs/ingress-dns.md`](docs/ingress-dns.md).
- **Homelab dashboard:** `hl.m6o.dev` (Homepage)

## Repository Structure

- `docs/` - Hardware inventory, network architecture, service guides
- `k3s/` - Kubernetes cluster setup, manifests, and Ansible playbooks

## Runbooks

- **DAS drive swap** on k3s-node-02 (`/mnt/r0`) → read [`docs/das-drive-swap.md`](docs/das-drive-swap.md) first. RAID 0 with no backup; five workloads mount it and two use strict hostPaths that block scheduling when it's absent.
- **PVC operations** (scaling apps down/up, stopping pods, restoring from Longhorn backup or host tarball) → read [`docs/pvc-maintenance.md`](docs/pvc-maintenance.md) first. PVCs and Deployments are owned by different Argo apps (`*-infra` vs per-service) and the root `media-apps` reconciles patches — naive `kubectl scale` or `selfHeal: false` will get reverted.
- **WiFi / mesh backhaul** (any "X is slow" report involving the k3s nodes, NAS or workstation) → read [`docs/wifi-mesh.md`](docs/wifi-mesh.md) first. All three UDBs reach the network over wireless mesh, and the controller's per-station MLO data actively lies — measure with the parent AP's `vwireap*` counters, never `uplink` / `downlink_table` / `STATE`.

## Network Architecture

Router: R18 UGC Max (UniFi)

Scheme: `10.10.<VLAN_ID>.x` — VLAN ID doubles as the subnet's third octet.

| VLAN | Subnet         | Hosts | IPv6                     | Purpose               |
| ---- | -------------- | ----- | ------------------------ | --------------------- |
| 1    | 10.10.1.0/24   | 254   | 2001:2042:37b0:1c00::/64 | UniFi management      |
| 10   | 10.10.10.0/24  | 254   | 2001:2042:37b0:1c01::/64 | Trusted (PCs, phones) |
| 20   | 10.10.20.0/24  | 254   | -                        | UniFi Protect         |
| 40   | 10.10.40.0/24  | 254   | -                        | Guest                 |
| 50   | 10.10.50.0/24  | 254   | -                        | Servers (k3s)         |
| 53   | 10.10.53.0/24  | 254   | 2001:2042:37b0:1c35::/64 | DNS (Pi-hole)         |
| 107  | 10.10.107.0/24 | 254   | -                        | IoT (lights, sensors) |

- Gateway at .1 in each VLAN (e.g. `10.10.10.1` for VLAN 10)
- Only Trusted (VLAN 10) can access Servers, IoT, and Protect; all others isolated
- All VLANs can reach Pi-hole (`10.10.53.53`) on port 53 for DNS
- Guest, Protect, Servers, DNS, and IoT have no IPv6 (simpler, more secure)
- DNS fallback: Quad9 (9.9.9.9, 149.112.112.112)
- VLAN 10's IPv6 comes from the ISP prefix delegation (`ipv6_interface_type: pd`), so its
  `/64` can change; VLAN 53's is statically configured. Never key config on a VLAN 10 IPv6
  address: hosts use SLAAC privacy addresses that rotate every few days on top of that.

### Expected-offline devices

- **AirWire** (`UAPEA07`): powered on only for occasional ad-hoc use, otherwise
  intentionally offline. In any network health check, treat its offline state as
  expected — do not flag or list it. **Any _other_ offline UniFi device is not
  expected and should be flagged.**

## Current Services

- **Pi-hole v6** in active/standby on two Raspberry Pis: Network-wide DNS resolver for ad/malware blocking. Clients use the floating keepalived VIP `10.10.53.53` / `2001:2042:37b0:1c35::53` (+ `100.100.53.53` on Tailscale, pihole-01 only). Setup + runbook: [`ansible/pihole.md`](ansible/pihole.md)
  - **HA:** `pihole-01` (RPi5, `.51`/`::51`, MASTER) + `pihole-02` (RPi3 B+, `.52`/`::52`, BACKUP). keepalived runs IPv4 (VRRPv2) + IPv6 (VRRPv3) VIP instances in one sync group; the `chk_pihole` health check runs a real DNS query, so a wedged-but-running FTL fails over. Deployed by `ansible/pihole/pihole.yaml` (single playbook, per-host vars).
  - **Sync:** `nebula-sync` on pihole-01 pushes config/blocklists pihole-01 → pihole-02 hourly via the v6 API/Teleporter (`RUN_GRAVITY=false` — the RPi3 hangs FTL on gravity rebuilds).
  - Config: `/etc/pihole/pihole.toml` (v6 uses TOML, not the legacy dnsmasq conf files)
  - v6 ignores `/etc/dnsmasq.d/` by default (`misc.etc_dnsmasq_d = false`) — must be explicitly enabled
  - DNS service: `pihole-FTL` (restart with `sudo systemctl restart pihole-FTL`)
  - **Unbound** runs as recursive resolver on `127.0.0.1:5335` on each node; Pi-hole uses it as upstream instead of Quad9 directly
  - DNS chain: Device → Pi-hole VIP (`:53`) → Unbound (`127.0.0.1:5335`) → root nameservers
- **UNAS-4** (UniFi NAS): Network-attached storage on VLAN 50 (`10.10.50.4`, shares the Servers VLAN with the k3s nodes so NFS stays intra-VLAN)
  - 4×24 TB 7200RPM HDD in RAID 5 (~72 TB usable) + 2×1 TB Intel 660p M.2 SSD (`md4` RAID 0) as an lvmcache
  - The lvmcache is in **`writethrough`** mode — reads are accelerated, writes are not. Every write lands on
    the RAID 5 array with its read-modify-write penalty; this is the NAS write ceiling.
  - NFS share `Media` (52 TB quota) exported to k3s nodes at `/var/nfs/shared/Media`
  - NFS share `Backups` exported to k3s nodes at `/var/nfs/shared/Backups`
  - NFS share `k3s` exported to k3s nodes at `/var/nfs/shared/k3s` — dedicated Longhorn backup target
  - `media-data` PVC mounts the full `Media` share; `dl/` and `lib/` are top-level subdirs — same mount enables hardlinks between download clients and ARR library moves
- **k3s cluster**: Multi-node Kubernetes (server + 2 agents) running Prometheus, Grafana, Loki, Promtail
  - Server: `k3s-server` (M75q-1) at `10.10.50.10`
  - Agent: `k3s-node-01` (M715Q) at `10.10.50.11`
  - Agent: `k3s-node-02` (M70q Gen 5) at `10.10.50.12`
  - MetalLB VIP: `10.10.50.3` (ingress target, split-DNS destination)
- **Cloudflare**: manages the `m6o.dev` domain, hosts the public website on the apex, and provides DNS-01 challenge validation for Let's Encrypt certificates via cert-manager. No Cloudflare Tunnel — no homelab services are publicly exposed.
- **Tailscale**: Private overlay network for remote access to k3s services and Pi-hole
  - Tailnet: `qilin-goby.ts.net`
  - k3s server: `100.100.50.10` (mirrors local `10.10.50.10`)
  - Pi-hole: `100.100.53.53` (mirrors local `10.10.53.53`)
  - Pi-hole split-DNS records: `<app>.m6o.dev → 10.10.50.3` (MetalLB VIP, via `/etc/dnsmasq.d/20-k3s.conf`)
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
