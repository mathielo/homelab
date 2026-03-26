# Pi-hole (AdBlocker)

Using a Raspberry Pi as the host for [Pi-hole](https://docs.pi-hole.net/) as the network's default DNS Resolver. All network traffic is meant to go through it to block unwanted ads, malware or any other type of blacklisted domains.

| Host   | LAN IP      | LAN IPv6                | Tailscale IP  |
| ------ | ----------- | ----------------------- | ------------- |
| pihole | 10.10.53.53 | 2001:2042:37b0:1c35::53 | 100.100.53.53 |

> Full hardware specs: [docs/hardware.md](../docs/hardware.md)

## Prerequisites

These steps are one-time manual steps that must be completed before running the Ansible playbooks.

### 1. Install Raspberry Pi OS

Use the official [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to flash **Raspberry Pi OS Lite (64-bit)** to the SD card. In the imager's advanced settings:

- Set hostname: `pihole`
- Set username: `m8hl`
- Enable SSH with password authentication (will be disabled by the bootstrap playbook)

### 2. Set a static IP

Pi-hole must have a static IP since it's the network's DNS resolver. SSH into the Pi (using the DHCP-assigned IP or `pihole.local`) and run:

```bash
# List connections to find the NAME of the active connection
nmcli connection show

# Set static IPv4 (replace netplan-eth0 with your connection name)
sudo nmcli connection modify "netplan-eth0" \
  ipv4.method manual \
  ipv4.addresses 10.10.53.53/24 \
  ipv4.gateway 10.10.53.1 \
  ipv4.dns "127.0.0.1"

# Apply changes (will briefly drop SSH connection)
sudo nmcli connection up "netplan-eth0"
```

> :bulb: DNS is set to `127.0.0.1` — the Pi resolves via its own Pi-hole → Unbound chain.

> :bulb: After this, the Pi is reachable at `10.10.53.53` — which is what the Ansible inventory uses.

### 3. Configure UniFi for IPv6

**VLAN 53 (DNS) — enable IPv6:**

- Networks → VLAN 53 → Edit → IPv6
- Interface Type: **Static**
- IPv6 Address: `2001:2042:37b0:1c35::1`, Netmask: `64`
- Client Address Assignment: **SLAAC**
- Router Advertisement (RA): enabled

**VLANs with IPv6 (1, 10) — set Pi-hole as IPv6 DNS:**

- Networks → VLAN → Edit → IPv6 → Advanced → Manual
- Uncheck **Auto DNS Server**, set DNS Server to `2001:2042:37b0:1c35::53`

**WAN — update DNS servers:**

- Settings → Internet → WAN1 → IPv4: Primary `10.10.53.53`, Secondary `9.9.9.9`
- Settings → Internet → WAN1 → IPv6: Primary `2001:2042:37b0:1c35::53`, Secondary `2620:fe::fe`

## Bootstrap

The bootstrap playbook configures the host for remote management:
- Passwordless sudo for the `m8hl` user
- SSH public key authentication (only the key in the playbook is authorized)
- Password-based SSH disabled

First run (password auth still enabled, credentials loaded from secrets):

```bash
cd ansible
ansible-playbook bootstrap.yaml --limit pihole
```

> :bulb: After bootstrap, SSH key auth is used for all subsequent playbooks.

> :warning: Once password SSH is disabled, losing your private key means you'll need physical access to recover. Keep a backup of your key.

## Install Pi-hole

Install Pi-hole using the official installer in unattended mode:

```bash
ansible-playbook pihole/pihole.yaml
```

This will:
- Write `/etc/pihole/setupVars.conf` with the network and DNS configuration
- Install Pi-hole (query logging enabled)
- Set the admin password from the secrets file
- Configure a static IPv6 address (`2001:2042:37b0:1c35::53/64`) on `eth0` via NetworkManager
- Install and configure Unbound as a recursive resolver on `127.0.0.1:5335`
- Configure Pi-hole to use Unbound as its upstream (`127.0.0.1#5335`)
- Enable `/etc/dnsmasq.d/` loading for wildcard DNS records

The admin panel is available at `http://10.10.53.53/admin` after installation.

> :bulb: This playbook targets **Pi-hole v6**. Key v6 differences:
> - Main config: `/etc/pihole/pihole.toml` (replaces legacy dnsmasq conf files)
> - DNS service: `pihole-FTL` — restart with `sudo systemctl restart pihole-FTL`
> - Config CLI: `sudo pihole-FTL --config <key> <value>` (e.g. `sudo pihole-FTL --config misc.etc_dnsmasq_d true`)
> - `/etc/dnsmasq.d/` is **ignored by default** (`misc.etc_dnsmasq_d = false`) — the playbook enables this to allow the `20-k3s.conf` wildcard record
> - `pihole setpassword` replaces v5's `pihole -a -p <password>`

## Tailscale

Pi-hole is a member of the tailnet so it can serve DNS to all tailnet devices regardless of their physical location. See [docs/tailscale.md](../docs/tailscale.md) for the overall architecture (IP convention, subnet routing, DNS flow).

### Setup

1. Run the Tailscale playbook to join Pi-hole to the tailnet:

```bash
ansible-playbook tailscale.yaml --limit pihole
```

2. In the **Tailscale admin console**, assign Pi-hole a static Tailscale IP so the DNS config never needs updating:
   - Go to the machine's settings → **Addresses** → set to `100.100.53.53`

3. Configure Tailscale to use Pi-hole as the DNS resolver for all tailnet devices:
   - Tailscale admin console → **Settings → DNS**
   - Add a **Global nameserver**: `100.100.53.53`
   - Enable **Override DNS servers**

### How it works

Pi-hole is configured with `DNSMASQ_LISTENING=all` so it accepts queries on all interfaces, including the Tailscale interface (`tailscale0`). Access to port 53 is controlled by UniFi firewall rules (all VLANs allowed) and Tailscale's network policy — it is not open to the internet.

DNS chain: Device → Pi-hole (`:53`) → Unbound (`127.0.0.1:5335`) → root nameservers

```
Home network device
  → UniFi DHCP → Pi-hole (10.10.53.53)

Tailnet device (any network)
  → Tailscale DNS override → Pi-hole (100.100.53.53)
```
