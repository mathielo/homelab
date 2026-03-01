# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a homelab repository for documenting, configuring, and automating a home network infrastructure. The setup uses **Ubiquiti UniFi** devices exclusively for all networking equipment.

## Working Style

- **Ask before assuming**: When requirements are ambiguous or unclear, ask clarifying questions before starting work. It's better to clarify upfront than waste effort on incorrect assumptions.
- **Target environment**: Linux (Pop_OS!) unless otherwise specified.
- **User context**: Seasoned developer comfortable with code, learning networking specifics and advanced features.
- **No git operations**: Do not commit, push, or perform other git operations unless explicitly asked. The user prefers to review all changes and commit themselves.

## Domain

- **Domain:** `mathielo.com` (managed in Cloudflare)
- **Homelab services:** exposed as `*.mathielo.com` via Cloudflare Tunnel (no open ports)

## Repository Structure

- `network/` - Network architecture documentation including VLAN segmentation
- `services/` - Individual service setup guides and configurations (e.g., Pi-hole)
- `k3s/` - Kubernetes cluster setup, manifests, and Ansible playbooks

## Network Architecture

Router: R18 UGC Max (UniFi)

Scheme: `10.10.<VLAN_ID>.x` — VLAN ID doubles as the subnet's third octet.

| VLAN | Subnet           | Hosts | IPv6                        | Purpose                      |
|------|------------------|-------|-----------------------------|------------------------------|
| 1    | 10.10.1.0/24     | 254   | 2001:2042:37b0:1c00::/64    | UniFi management             |
| 10   | 10.10.10.0/24    | 254   | 2001:2042:37b0:1c02::/64    | Trusted (PCs, phones)        |
| 40   | 10.10.40.0/24    | 254   | -                           | Guest                        |
| 50   | 10.10.50.0/24    | 254   | -                           | Servers (k3s, future NAS)    |
| 53   | 10.10.53.0/24    | 254   | -                           | DNS (Pi-hole)                |
| 107  | 10.10.107.0/24   | 254   | -                           | IoT (lights, sensors)        |

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
- **k3s cluster** on Lenovo ThinkCentre M715Q: Single-node Kubernetes running Prometheus, Grafana, Alertmanager
- **Cloudflare Tunnel**: Exposes k3s services as `*.mathielo.com` without opening ports
- **Tailscale**: Private overlay network for internal access to k3s services
  - Tailnet: `qilin-goby.ts.net`
  - k3s node: `k3s.qilin-goby.ts.net` / `100.100.50.3` (mirrors local `10.10.50.3`)
  - Pi-hole: `100.100.53.53` (mirrors local `10.10.53.53`)
  - Pi-hole wildcard record: `*.hl → 100.100.50.3` (via `/etc/dnsmasq.d/20-k3s.conf`)

## MCP Access Policy

Claude has MCP access to Pi-hole and UniFi for **read-only purposes**:

- **DO NOT** make any changes directly to Pi-hole or UniFi
- **DO** query and display current configurations, rules, clients, etc.
- **DO** provide guidance and commands/steps for the user to apply changes manually
- The user wants to learn by applying changes themselves

## Planned Expansions

- Backup solutions
- NFS (Network File System)
- VPN (Wireguard or UniFi Teleport)
