# WiFi & Network setup

For security and traffic optimization, the network is subdivided in separate Virtual LANs (VLANs), each with their own purpose and level of access.

The access points provide different WiFi networks, and each of them connect directly to their respective VLAN:

| ID  | Name    | WiFi SSID  | Bands (GHz) | SSID Broadcast | Inter-VLAN access | Purpose                                         |
| --- | ------- | ---------- | ----------- | -------------- | ----------------- | ----------------------------------------------- |
| 10  | Trusted | 221B       | 2.4 / 5 / 6 | Yes            | Media + IoT       | Trusted devices (PCs, phones)                   |
| 20  | Media   | 221B Media | 2.4 / 5     | No             | None              | Media playing devices (TVs, speakers)           |
| 30  | IoT     | 221B IoT   | 2.4         | No             | None              | All IoT devices (lights, robot vacuum, sensors) |
| 40  | Guest   | 221B Guest | 5           | Yes            | None              | Friends and visitors                            |

All VLANs have internet access (some might have speed limits established e.g. Guest network). Only devices in the Trusted VLAN can access devices in other VLANs; otherwise devices have access limited to the VLAN in which they reside.

# DNS Configuration through Pi-hole

After properly setting up the local [Pi-hole](../services/pi-hole/README.md), configure UniFi to use Pi-hole as the DNS resolver for all VLANs.

## Per-VLAN DHCP Settings

For each VLAN in **Settings → Networks → [VLAN] → DHCP**:

| Setting       | Value                    |
| ------------- | ------------------------ |
| Primary DNS   | 192.168.10.9 (Pi-hole)   |
| Secondary DNS | 9.9.9.9 (Quad9 fallback) |
| IPv6 DNS      | Auto                     |

This ensures **per-client** visibility in Pi-hole logs for statistics and **per-device blocking**.

## WAN DNS Settings

In **Settings → Internet → [WAN] → DNS**:

| Protocol | Primary      | Secondary  |
| -------- | ------------ | ---------- |
| IPv4     | 192.168.10.9 | 9.9.9.9    |
| IPv6     | 2620:fe::fe  | 2620:fe::9 |

This ensures the **router itself** uses Pi-hole for its own DNS queries.

## Firewall Rules

Since Pi-hole is on VLAN 10 (Trusted) and other VLANs are isolated, firewall rules are needed to allow DNS traffic.

In **Settings → Firewall & Security → Firewall Rules**, create a LAN rule:

| Setting     | Value                                      |
| ----------- | ------------------------------------------ |
| Name        | Allow DNS to Pi-hole                       |
| Action      | Allow                                      |
| Source      | All VLANs (or specific: Media, IoT, Guest) |
| Destination | 192.168.10.9                               |
| Port        | 53                                         |
| Protocol    | TCP and UDP                                |

Place this rule **before** any inter-VLAN block rules.
