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

The network is segmented into four VLANs:

| VLAN | Name    | Purpose                          | Inter-VLAN Access |
|------|---------|----------------------------------|-------------------|
| 10   | Trusted | PCs, phones, trusted devices     | Can access Media + IoT |
| 20   | Media   | TVs, speakers, media devices     | Isolated |
| 30   | IoT     | Lights, sensors, smart devices   | Isolated |
| 40   | Guest   | Visitors                         | Isolated |

All VLANs have internet access. Only the Trusted VLAN can communicate with other VLANs.

## Current Services

- **Pi-hole** on Raspberry Pi 5: Network-wide DNS resolver for ad/malware blocking

## Planned Expansions

- Backup solutions
- NFS (Network File System)
- VPN (Wireguard or UniFi Teleport)
