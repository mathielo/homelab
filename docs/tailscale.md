# Tailscale

Tailscale is a private overlay network (tailnet) that provides secure remote access to homelab services without exposing any ports to the internet. It runs on top of WireGuard.

Tailnet: `qilin-goby.ts.net`

## Why Tailscale

The homelab is only accessible from the LAN by default — all services live behind Pi-hole split-DNS and UniFi firewall rules, with no public-facing ports. Tailscale extends this access to devices outside the home network (laptop on coffee shop WiFi, phone on mobile data) without opening anything to the internet.

## IP Convention

Tailscale IPs mirror the LAN IP scheme for easy mental mapping:

| Host        | LAN IP      | Tailscale IP  | Mnemonic            |
| ----------- | ----------- | ------------- | ------------------- |
| k3s-node-01 | 10.10.50.3  | 100.100.50.3  | `10.10` → `100.100` |
| pihole      | 10.10.53.53 | 100.100.53.53 | `10.10` → `100.100` |

These are **static Tailscale IPs**, manually assigned in the Tailscale admin console (Machine settings → Addresses) so they never change. The convention is `100.100.<VLAN>.<host>`, matching the LAN scheme `10.10.<VLAN>.<host>`.

## Subnet Routing

The k3s node advertises the Servers VLAN (`10.10.50.0/24`) as a Tailscale subnet route. This means remote tailnet devices can reach services at their **LAN IPs** (e.g. `10.10.50.3`) even though they're not physically on the LAN.

This is what makes the wildcard DNS record work remotely: Pi-hole resolves `*.hl.mathielo.com` to `10.10.50.3`, and the subnet route ensures that IP is reachable from anywhere on the tailnet.

Subnet routes must be approved in the **Tailscale admin console** → Machines → k3s-node-01 → Edit route settings → enable `10.10.50.0/24`.

## DNS: Putting It All Together

Pi-hole serves as the DNS resolver for **all** tailnet devices, not just LAN devices. This is configured via Tailscale's global nameserver override.

```
LAN device
  → UniFi DHCP assigns Pi-hole (10.10.53.53) as DNS
  → Pi-hole resolves *.hl.mathielo.com → 10.10.50.3
  → Device reaches 10.10.50.3 directly (same LAN)

Remote tailnet device
  → Tailscale DNS override → Pi-hole (100.100.53.53)
  → Pi-hole resolves *.hl.mathielo.com → 10.10.50.3
  → Subnet route delivers traffic to 10.10.50.3 via tailnet
```

The result: `https://grafana.hl.mathielo.com` works identically whether you're at home or on the other side of the world.

## Setup

Tailscale is installed on hosts via the shared Ansible playbook:

```bash
ansible-playbook tailscale.yaml --limit <host>
```

The playbook uses a reusable auth key from `ansible/group_vars/all/secrets.sops.yaml`. For host-specific setup steps (static IP assignment, admin console config), see:

- [Pi-hole Tailscale setup](../ansible/pihole.md#tailscale)
- [k3s Tailscale setup](../ansible/k3s.md#tailscale)
