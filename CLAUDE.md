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

| VLAN | Subnet            | Hosts | IPv6                        | Purpose                      |
|------|-------------------|-------|-----------------------------|------------------------------|
| 1    | 192.168.1.0/27    | 29    | 2001:2042:37b0:1c00::/64    | UniFi management             |
| 10   | 192.168.10.0/27   | 29    | 2001:2042:37b0:1c02::/64    | Trusted (PCs, phones)        |
| 20   | 192.168.20.0/27   | 29    | 2001:2042:37b0:1c01::/64    | Media (TVs, speakers)        |
| 30   | 192.168.30.0/26   | 61    | -                           | IoT (lights, sensors)        |
| 40   | 192.168.40.0/28   | 13    | -                           | Guest                        |

- Gateway at .1 in each VLAN
- Only Trusted (VLAN 10) can access Media + IoT; all others isolated
- IoT and Guest have no IPv6 (simpler, more secure for those device types)
- DNS fallback: Quad9 (9.9.9.9, 149.112.112.112)

## Current Services

- **Pi-hole** on Raspberry Pi 5: Network-wide DNS resolver for ad/malware blocking
- **k3s cluster** on Lenovo ThinkCentre M715Q: Single-node Kubernetes running Prometheus, Grafana, Alertmanager
- **Cloudflare Tunnel**: Exposes k3s services as `*.mathielo.com` without opening ports
- **Tailscale**: Private overlay network for internal access to k3s services
  - Tailnet: `qilin-goby.ts.net`
  - k3s node: `k3s.qilin-goby.ts.net` / `100.93.65.44`
  - Pi-hole wildcard record: `*.hl → 100.93.65.44` (via `/etc/dnsmasq.d/20-k3s.conf`)

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
