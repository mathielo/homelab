# WiFi & Network setup

For security and traffic optimization, the network is subdivided in separate Virtual LANs (VLANs), each with their own purpose and level of access.

The access points provide different WiFi networks, and each of them connect directly to their respective VLAN:

| ID  | Name    | Subnet         | WiFi SSID  | Bands (GHz) | SSID Broadcast | Inter-VLAN access | Purpose                                         |
| --- | ------- | -------------- | ---------- | ----------- | -------------- | ----------------- | ----------------------------------------------- |
| 1   | UniFi   | 10.10.1.0/24   | -          | -           | -              | -                 | UniFi management (router, switches, APs, cams)  |
| 10  | Trusted | 10.10.10.0/24  | 221B       | 2.4 / 5 / 6 | Yes            | Servers + IoT     | Trusted devices (PCs, phones)                   |
| 40  | Guest   | 10.10.40.0/24  | 221B Guest | 5           | Yes            | None              | Friends and visitors                            |
| 50  | Servers | 10.10.50.0/24  | -          | -           | -              | -                 | k3s cluster                                     |
| 53  | DNS     | 10.10.53.0/24  | -          | -           | -              | -                 | Pi-hole DNS resolver                            |
| 107 | IoT     | 10.10.107.0/24 | 221B IoT   | 2.4         | No             | None              | All IoT devices (lights, robot vacuum, sensors) |

All VLANs have internet access (some might have speed limits established e.g. Guest network). Only devices in the Trusted VLAN can access Servers and IoT VLANs; otherwise devices have access limited to the VLAN in which they reside. All VLANs can reach Pi-hole on port 53 for DNS.

# DNS Configuration through Pi-hole

After properly setting up the local [Pi-hole](../ansible/pihole.md), configure UniFi to use Pi-hole as the DNS resolver for all VLANs.

## Per-VLAN DHCP Settings

For each VLAN in **Settings → Networks → [VLAN] → DHCP**:

| Setting           | Value                        |
| ----------------- | ---------------------------- |
| Primary DNS       | `10.10.53.53` (Pi-hole)      |
| ~~Secondary DNS~~ | ~~9.9.9.9 (Quad9 fallback)~~ |
| IPv6 DNS          | `2001:2042:37b0:1c35::53`    |

> :bulb: There are no secondary DNS resolvers for any VLANs. This makes the Pi-hole the sole DNS resolver for the entire network.
>
> While this ensures all traffic is properly filtered and controlled by the Pi-hole, it also turns it into a single point of failure. If the Pi-hole is down, all DNS resolving stops in the network.

This ensures **per-client** visibility in Pi-hole logs for statistics and **per-device blocking**.

## WAN DNS Settings

In **Settings → Internet → [WAN] → DNS**:

| Protocol | Primary     | Secondary  |
| -------- | ----------- | ---------- |
| IPv4     | 10.10.53.53 | 9.9.9.9    |
| IPv6     | 2620:fe::fe | 2620:fe::9 |

This ensures the **router itself** uses Pi-hole for its own DNS queries. Quad9 is used as backup resolver for the WAN.

## Firewall Rules

UniFi uses a **zone-based firewall** (Settings → Firewall & Security → Zones & Policies).

### Zone Assignments

VLANs are grouped into zones, which define the default trust level between them:

| Zone     | VLANs                                                               |
| -------- | ------------------------------------------------------------------- |
| Internal | VLAN 1 (UniFi), VLAN 10 (Trusted), VLAN 50 (Servers), VLAN 53 (DNS) |
| Hotspot  | VLAN 40 (Guest)                                                     |
| Limited  | VLAN 107 (IoT)                                                      |
| External | WAN interfaces                                                      |

Because Trusted, Servers, and DNS all share the Internal zone, they can freely communicate with each other by default.

### Zone Matrix (default policies)

| Source → Destination | Internal     | Hotspot   | Limited   | External  |
| -------------------- | ------------ | --------- | --------- | --------- |
| **Internal**         | Allow All    | Allow All | Block All | Allow All |
| **Hotspot**          | Allow Return | Block All | Block All | Allow All |
| **Limited**          | Block All    | Block All | Block All | Allow All |

### Custom Firewall Policies

The zone matrix defaults handle most access control, but a few explicit policies are needed in **Settings → Firewall & Security → Firewall Policies**:

| Name                           | Src. Zone | Src. | Dst. Zone | Dst.        | Port | Protocol    |
| ------------------------------ | --------- | ---- | --------- | ----------- | ---- | ----------- |
| Allow "Hotspot" DNS to Pi-hole | Hotspot   | Any  | Internal  | 10.10.53.53 | 53   | TCP and UDP |
| Allow "Limited" DNS to Pi-hole | Limited   | Any  | Internal  | 10.10.53.53 | 53   | TCP and UDP |
| Allow "Internal" → Limited     | Internal  | Any  | Limited   | Any         | Any  | Any         |

**What each rule covers:**

- The two DNS rules punch through the zone defaults to allow Guest and IoT devices to reach Pi-hole for DNS, while remaining isolated from everything else in the Internal zone.
- The Internal → Limited rule allows Trusted devices (VLAN 10) to reach IoT devices (VLAN 107). The broader Internal → Limited scope (rather than just VLAN 10) is acceptable since Servers and DNS VLANs have no reason to initiate connections to IoT devices in practice.
- Pi-hole admin access (HTTP/HTTPS) from Trusted to VLAN 53 is covered implicitly by the Internal → Internal "Allow All" default.
- Trusted → Servers access is also covered implicitly by Internal → Internal "Allow All".
