# WiFi & Network setup

For security and traffic optimization, the network is subdivided in separate Virtual LANs (VLANs), each with their own purpose and level of access.

The access points provide different WiFi networks, and each of them connect directly to their respective VLAN:

| ID  | Name    | Subnet           | WiFi SSID  | Bands (GHz) | SSID Broadcast | Inter-VLAN access  | Purpose                                         |
| --- | ------- | ---------------- | ---------- | ----------- | -------------- | ------------------ | ----------------------------------------------- |
| 1   | UniFi   | 10.10.1.0/24     | -          | -           | -              | -                  | UniFi management (router, switches, APs, cams)  |
| 10  | Trusted | 10.10.10.0/24    | 221B       | 2.4 / 5 / 6 | Yes            | Servers + IoT      | Trusted devices (PCs, phones)                   |
| 40  | Guest   | 10.10.40.0/24    | 221B Guest | 5           | Yes            | None               | Friends and visitors                            |
| 50  | Servers | 10.10.50.0/24    | -          | -           | -              | -                  | k3s cluster, future NAS                         |
| 53  | DNS     | 10.10.53.0/24    | -          | -           | -              | -                  | Pi-hole DNS resolver                            |
| 107 | IoT     | 10.10.107.0/24   | 221B IoT   | 2.4         | No             | None               | All IoT devices (lights, robot vacuum, sensors) |

All VLANs have internet access (some might have speed limits established e.g. Guest network). Only devices in the Trusted VLAN can access Servers and IoT VLANs; otherwise devices have access limited to the VLAN in which they reside. All VLANs can reach Pi-hole on port 53 for DNS.

# DNS Configuration through Pi-hole

After properly setting up the local [Pi-hole](../services/pi-hole/README.md), configure UniFi to use Pi-hole as the DNS resolver for all VLANs.

## Per-VLAN DHCP Settings

For each VLAN in **Settings → Networks → [VLAN] → DHCP**:

| Setting       | Value                    |
| ------------- | ------------------------ |
| Primary DNS   | 10.10.53.53 (Pi-hole)    |
| Secondary DNS | 9.9.9.9 (Quad9 fallback) |
| IPv6 DNS      | Auto                     |

This ensures **per-client** visibility in Pi-hole logs for statistics and **per-device blocking**.

## WAN DNS Settings

In **Settings → Internet → [WAN] → DNS**:

| Protocol | Primary      | Secondary  |
| -------- | ------------ | ---------- |
| IPv4     | 10.10.53.53  | 9.9.9.9    |
| IPv6     | 2620:fe::fe  | 2620:fe::9 |

This ensures the **router itself** uses Pi-hole for its own DNS queries.

## Firewall Rules

Pi-hole is on its own VLAN 53 (DNS), isolated from all other VLANs. Firewall rules are needed to allow DNS traffic from all VLANs, and admin access from Trusted only.

In **Settings → Firewall & Security → Firewall Rules**, create LAN rules:

| Name                   | Action | Source         | Destination  | Port    | Protocol    |
| ---------------------- | ------ | -------------- | ------------ | ------- | ----------- |
| Allow DNS to Pi-hole   | Allow  | All VLANs      | 10.10.53.53  | 53      | TCP and UDP |
| Allow Pi-hole admin    | Allow  | VLAN 10        | 10.10.53.0/24 | 80, 443 | TCP         |
| Trusted → Servers      | Allow  | VLAN 10        | 10.10.50.0/24 | any     | any         |
| Trusted → IoT          | Allow  | VLAN 10        | 10.10.107.0/24 | any    | any         |

Place these rules **before** any inter-VLAN block rules.
