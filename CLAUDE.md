# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a homelab repository for documenting, configuring, and automating a home network infrastructure. The setup uses **Ubiquiti UniFi** devices exclusively for all networking equipment.

## Working Style

- **Ask before assuming**: When requirements are ambiguous or unclear, ask clarifying questions before starting work. It's better to clarify upfront than waste effort on incorrect assumptions.
- **Target environment**: Linux (Pop_OS!) unless otherwise specified.
- **User context**: Seasoned developer comfortable with code, learning networking specifics and advanced features.

## Repository Structure

- `network/` - Network architecture documentation including VLAN segmentation
- `services/` - Individual service setup guides and configurations (e.g., Pi-hole)

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

## Planned Expansions

- Backup solutions
- NFS (Network File System)
- VPN (Wireguard or UniFi Teleport)
