# Tailscale

Tailscale is a private overlay network (tailnet) that provides secure remote access to homelab services without exposing any ports to the internet. It runs on top of WireGuard.

Tailnet: `qilin-goby.ts.net`

## Why Tailscale

The homelab is only accessible from the LAN by default — all services live behind Pi-hole split-DNS and UniFi firewall rules, with no public-facing ports. Tailscale extends this access to devices outside the home network (laptop on coffee shop WiFi, phone on mobile data) without opening anything to the internet.

## IP Convention

Tailscale IPs mirror the LAN IP scheme for easy mental mapping:

| Host       | LAN IP      | Tailscale IP  | Mnemonic            |
| ---------- | ----------- | ------------- | ------------------- |
| k3s-server | 10.10.50.10 | 100.100.50.10 | `10.10` → `100.100` |
| pihole     | 10.10.53.53 | 100.100.53.53 | `10.10` → `100.100` |

These are **static Tailscale IPs**, manually assigned in the Tailscale admin console (Machine settings → Addresses) so they never change. The convention is `100.100.<VLAN>.<host>`, matching the LAN scheme `10.10.<VLAN>.<host>`.

## Subnet Routing

The k3s server node advertises the Servers VLAN (`10.10.50.0/24`) as a Tailscale subnet route. This means remote tailnet devices can reach services at their **LAN IPs** (e.g. `10.10.50.3`, the MetalLB VIP) even though they're not physically on the LAN.

This is what makes the wildcard DNS record work remotely: Pi-hole resolves `*.m6o.dev` to `10.10.50.3` (MetalLB VIP), and the subnet route ensures that IP is reachable from anywhere on the tailnet.

Subnet routes must be approved in the **Tailscale admin console** → Machines → k3s-server → Edit route settings → enable `10.10.50.0/24`.

## DNS: Putting It All Together

Pi-hole serves as the DNS resolver for **all** tailnet devices, not just LAN devices. This is configured via Tailscale's global nameserver override.

```
LAN device
  → UniFi DHCP assigns Pi-hole (10.10.53.53) as DNS
  → Pi-hole resolves *.m6o.dev → 10.10.50.3 (MetalLB VIP)
  → MetalLB routes to nginx ingress → backend pod

Remote tailnet device
  → Tailscale DNS override → Pi-hole (100.100.53.53)
  → Pi-hole resolves *.m6o.dev → 10.10.50.3 (MetalLB VIP)
  → Subnet route delivers traffic to 10.10.50.3 via tailnet
  → MetalLB routes to nginx ingress → backend pod
```

The result: `https://grafana.m6o.dev` works identically whether you're at home or on the other side of the world.

## Direct Connections (NAT Traversal)

Every Tailscale connection starts relayed through a DERP server and upgrades to a **direct** peer-to-peer path when one is available. Because Pi-hole is the sole DNS resolver for the whole tailnet, a cold or relay-only tunnel makes the _first_ DNS lookup after a device has been idle slow — which stalls every app until the path warms up. The fix is to ensure a fast, reliable direct path exists, especially for mobile devices on cellular.

The home WAN has a normal public IP (no CGNAT) and native IPv6. **IPv6 is the key**: it has no NAT, so Tailscale prefers it and a direct path forms in almost every situation when both ends have it (home and the phone's mobile carrier both do). IPv4 direct is unreliable here — the gateway maps `tailscaled`'s `41641` to a random external port and advertises _that_, so a fixed `41641` forward rarely matches. UPnP/NAT-PMP is deliberately **not** enabled (avoids letting arbitrary LAN devices open ports).

`tailscaled` listens on the default UDP port `41641` on each host. Two firewall objects make direct connections work:

| Object                         | Type          | Config                                                                      | Purpose                                                                            |
| ------------------------------ | ------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `Tailnet External -> Internal` | Firewall rule | IPv6 · UDP · `External` → `Internal` · dest IID `::51/::53` · dport `41641` | Lets a remote device punch a **direct IPv6** path to pihole-01 on its first packet |
| `Tailscale Direct`             | Port forward  | WAN1 · UDP `41641` → `10.10.53.51`                                          | Best-effort IPv4 fallback (usually superseded by the IPv6 path)                    |

Notes:

- The firewall rule matches on **IID** (interface identifier `::51`/`::53`) rather than the full address, so it survives a change to the ISP's delegated IPv6 prefix. `::51` is pihole-01's stable address; `::53` is the keepalived VIP.
- A remote device _initiates_ outbound, so only the **home** inbound needs opening — there's no matching rule on the device side.
- The port forward targets pihole-01's real `.51`, **not** the floating VIP `.53` (which can move to pihole-02, where Tailscale isn't running).
- Part of the post-idle delay on iOS is the VPN network extension cold-booting on the device, which no network-side change can remove.

**Validating a direct path** — watch passively on pihole-01 while waking a long-idle device. Do **not** `tailscale ping` from home: that punches the path open from the home side and masks whether the device established direct on its own.

```bash
# Replace DEVICE with the tailnet device name (from `tailscale status`)
ssh pihole-01 'for i in $(seq 1 60); do printf "%s | " "$(date +%H:%M:%S)"; tailscale status | grep -i DEVICE; sleep 1; done'
```

A healthy result shows `active; direct [2a00:…]:41641` (direct over IPv6) shortly after the device wakes, rather than lingering on `active; relay "hel"`.

## Setup

Tailscale is installed on hosts via the shared Ansible playbook:

```bash
ansible-playbook tailscale.yaml --limit <host>
```

The playbook uses a reusable auth key from `ansible/group_vars/all/secrets.sops.yaml`. For host-specific setup steps (static IP assignment, admin console config), see:

- [Pi-hole Tailscale setup](../ansible/pihole.md#tailscale)
- [k3s Tailscale setup](../ansible/k3s.md#tailscale)
