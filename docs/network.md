# WiFi & Network setup

For security and traffic optimization, the network is subdivided in separate Virtual LANs (VLANs), each with their own purpose and level of access.

The access points provide different WiFi networks, and each of them connect directly to their respective VLAN:

| ID  | Name    | Subnet         | WiFi SSID  | Bands (GHz) | SSID Broadcast | Inter-VLAN access | Purpose                                         |
| --- | ------- | -------------- | ---------- | ----------- | -------------- | ----------------- | ----------------------------------------------- |
| 1   | UniFi   | 10.10.1.0/24   | -          | -           | -              | -                 | UniFi management (router, switches, APs)        |
| 10  | Trusted | 10.10.10.0/24  | 221B       | 2.4 / 5 / 6 | Yes            | Servers + IoT     | Trusted devices (PCs, phones)                   |
| 20  | Protect | 10.10.20.0/24  | -          | -           | -              | None              | UniFi Protect (cameras, NVR, sensors)           |
| 40  | Guest   | 10.10.40.0/24  | 221B Guest | 5           | Yes            | None              | Friends and visitors                            |
| 50  | Servers | 10.10.50.0/24  | -          | -           | -              | -                 | k3s cluster                                     |
| 53  | DNS     | 10.10.53.0/24  | -          | -           | -              | -                 | Pi-hole DNS resolver                            |
| 107 | IoT     | 10.10.107.0/24 | 221B IoT   | 2.4         | No             | None              | All IoT devices (lights, robot vacuum, sensors) |

Most VLANs have internet access (some with speed limits, e.g. Guest); the Protect VLAN is internet-isolated except for the NVR. Only devices in the Trusted VLAN can reach the Servers, IoT, and Protect VLANs; otherwise devices are limited to the VLAN in which they reside. All VLANs can reach Pi-hole on port 53 for DNS — and **only** Pi-hole, since direct/external DNS is blocked (see [Firewall Rules](#firewall-rules)).

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

| Protocol | Primary     | Secondary       |
| -------- | ----------- | --------------- |
| IPv4     | 9.9.9.9     | 149.112.112.112 |
| IPv6     | 2620:fe::fe | 2620:fe::9      |

The **router itself** uses external resolvers (Quad9) for its own DNS, **not** the internal Pi-hole. Pointing the gateway's WAN DNS at Pi-hole creates a dependency loop — if Pi-hole/Unbound is down the gateway can't resolve for NTP, firmware, or cloud. Clients still resolve through Pi-hole via the per-VLAN DHCP setting above; only the gateway's own lookups use Quad9 directly.

## Firewall Rules

UniFi uses a **zone-based firewall** (Settings → Security → Firewall). Every VLAN belongs to a zone, and a zone matrix sets the default action between zones. Traffic **within** a zone is allowed by default — so isolation comes from putting VLANs in separate zones, then adding explicit policies only for the flows that must cross.

### Zone Assignments

| Zone       | VLANs                                               |
| ---------- | --------------------------------------------------- |
| Management | VLAN 1 (UniFi)                                      |
| Internal   | VLAN 10 (Trusted), VLAN 50 (Servers), VLAN 53 (DNS) |
| Protect    | VLAN 20 (UniFi Protect: cameras, NVR, sensors)      |
| Hotspot    | VLAN 40 (Guest)                                     |
| Limited    | VLAN 107 (IoT)                                      |
| External   | WAN interfaces                                      |

Management (network gear), Protect, IoT, and Guest each sit in their own zone, so they're isolated from everything by default. Trusted, Servers, and DNS share Internal — they trust each other, so Trusted reaches the k3s services and Pi-hole admin with no explicit rule.

### Custom Firewall Policies

Beyond the zone defaults, explicit policies cover three things.

**1. DNS leak prevention** — force every client through Pi-hole, blocking any bypass. One pair of rules per client zone (Internal, Limited, Hotspot, Protect):

| Policy                   | Source        | Destination                             | Action |
| ------------------------ | ------------- | --------------------------------------- | ------ |
| Block ext DNS – \<zone\> | client zone   | External — ports 53, 853                | Block  |
| Block DoH – \<zone\>     | client zone   | External — known DoH resolver IPs : 443 | Block  |
| Allow DNS → NTP          | DNS (VLAN 53) | External                                | Allow  |

This drops plaintext DNS (53), DoT/DoQ (853), and DoH (443 to known providers) to anything other than Pi-hole. The **DNS VLAN is excluded** from the blocks so the recursive resolver can still reach root nameservers and NTP.

> The Internal block covers VLAN 50 (Servers), so cluster workloads that probe external nameservers directly will time out — notably cert-manager's DNS-01 self-check, which is pinned to Pi-hole (`10.10.53.53`) to compensate. See [`ingress-dns.md`](ingress-dns.md#3-tls-certificates-cert-manager--cloudflare).

**2. Pi-hole reachability** — isolated zones still need the resolver:

| Policy                          | Source                | Destination  |
| ------------------------------- | --------------------- | ------------ |
| Allow "\<zone\>" DNS to Pi-hole | Guest / IoT / Protect | Pi-hole : 53 |

Trusted/Servers reach Pi-hole implicitly (same Internal zone).

**3. Protect** — the Protect devices (cameras, sensors) are internet-isolated; only the NVR talks out:

| Policy                   | Source            | Destination  | Action |
| ------------------------ | ----------------- | ------------ | ------ |
| Allow UNVR → Internet    | NVR (fixed IP)    | External     | Allow  |
| Block Protect → Internet | Protect zone      | External     | Block  |
| Allow Trusted → Protect  | Trusted (VLAN 10) | Protect zone | Allow  |

The NVR keeps internet (firmware, remote access via the UniFi cloud); the cameras and other Protect devices don't. Trusted can view the Protect console/devices. Device↔NVR is intra-zone, so recording and adoption need no rule.

Plus **Allow Trusted → IoT** for casting/control of IoT devices.

> :bulb: **Order matters within a zone-pair.** In Protect → External the NVR allow sits above the device block, and the DNS/DoH blocks sit above both — so even the NVR is forced through Pi-hole while still reaching the internet for everything else.
