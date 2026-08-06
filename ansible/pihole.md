# Pi-hole (AdBlocker)

Using a Raspberry Pi as the host for [Pi-hole](https://docs.pi-hole.net/) as the network's default DNS Resolver. All network traffic is meant to go through it to block unwanted ads, malware or any other type of blacklisted domains.

Two nodes run in active/standby. `10.10.53.53` / `::53` are **keepalived VRRP virtual IPs** (IPv4 + IPv6, in one sync group) that float between the nodes, so clients always target one address that transparently fails over. keepalived health-checks `pihole-FTL` with a real DNS query, so a wedged-but-running FTL is caught and the standby takes over.

| Host      | Role             | LAN IP      | LAN IPv6                | Tailscale IP  |
| --------- | ---------------- | ----------- | ----------------------- | ------------- |
| —         | VIP (keepalived) | 10.10.53.53 | 2001:2042:37b0:1c35::53 | —             |
| pihole-01 | MASTER (RPi5)    | 10.10.53.51 | 2001:2042:37b0:1c35::51 | 100.100.53.53 |
| pihole-02 | BACKUP (RPi3 B+) | 10.10.53.52 | 2001:2042:37b0:1c35::52 | —             |

> Full hardware specs: [docs/hardware.md](../docs/hardware.md)

## Prerequisites

These steps are one-time manual steps that must be completed before running the Ansible playbooks.

### 1. Install Raspberry Pi OS

Use the official [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to flash **Raspberry Pi OS Lite (64-bit)** to the SD card. In the imager's advanced settings:

- Set hostname: `pihole-01` (RPi5) or `pihole-02` (RPi3 B+)
- Set username: `m8hl`
- Enable SSH with password authentication (will be disabled by the bootstrap playbook)

### 2. Set a static IP

Each node needs a static IP since they back the network's DNS resolver. Use `10.10.53.51` for `pihole-01` and `10.10.53.52` for `pihole-02` (the `.53` VIP is owned by keepalived — never assign it to an interface). SSH into the Pi (using the DHCP-assigned IP or `pihole.local`) and run:

```bash
# List connections to find the NAME of the active connection
nmcli connection show

# Set static IPv4 (replace netplan-eth0 with your connection name,
# and the address with .51 or .52 for this node)
sudo nmcli connection modify "netplan-eth0" \
  ipv4.method manual \
  ipv4.addresses 10.10.53.51/24 \
  ipv4.gateway 10.10.53.1 \
  ipv4.dns "127.0.0.1,10.10.53.53"

# Apply changes (will briefly drop SSH connection)
sudo nmcli connection up "netplan-eth0"
```

> :bulb: DNS is `127.0.0.1` first — the Pi resolves via its own Pi-hole → Unbound chain — with the VIP as fallback, so a node whose FTL is down (or not installed yet, on a rebuild) still resolves via the other one. The playbook re-asserts both.

> :bulb: After this the node is reachable at its `.51`/`.52` address — which is what the Ansible inventory uses.

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

This will, on **both** nodes:

- Write `/etc/pihole/setupVars.conf` with the network and DNS configuration
- Install Pi-hole (query logging enabled)
- Set the admin password from the secrets file
- Configure a static IPv6 address on `eth0` via NetworkManager (`::51` on pihole-01, `::52` on pihole-02) plus the `127.0.0.1,10.10.53.53` resolver pair; `::53` floats as the IPv6 VIP via keepalived
- Install and configure Unbound as a recursive resolver on `127.0.0.1:5335`
- Configure Pi-hole to use Unbound as its upstream (`127.0.0.1#5335`)
- Enable `/etc/dnsmasq.d/` loading for wildcard DNS records
- Install **keepalived** with a `pihole-FTL` health check (a real query, so a wedged FTL is caught); two VRRP instances — IPv4 `10.10.53.53` + IPv6 `::53` — in one sync group so both VIPs fail over together. The node holds state per `keepalived_state`/`keepalived_priority` (host_vars); `keepalived_start=false` stages it masked (used during cutover)

And on **pihole-01 only** (`nebula_sync_host: true`):

- Install [nebula-sync](https://github.com/lovelaze/nebula-sync) (arm64 binary + systemd unit) to replicate Pi-hole config and list definitions from pihole-01 → pihole-02 on a cron. It authenticates with the admin web password (`pihole_password` from `pihole.sops.yaml`) — no app password needed. `systemctl restart nebula-sync` triggers a sync immediately, rather than waiting for the next cron slot.

The admin panel is available at `http://10.10.53.53/admin` (VIP) after installation, or directly per node at `.51`/`.52`.

### Rebuilding a node

After a reinstall, run gravity **once** on the rebuilt node:

```bash
ssh pihole-02 "sudo pihole -g"
```

nebula-sync runs with `RUN_GRAVITY=false`, and Teleporter replicates the `adlist` rows — including their per-list `number` counts — but not the `gravity` table those counts describe. A rebuilt node therefore reports the full blocklist in the UI while actually holding only the lists it fetched itself (the installer's default), so it would block a fraction of what the other node does if it took over. `pihole -g` is also needed on the replica whenever adlists change.

> :bulb: Run it while the node is the standby: the rebuild is heavy SD I/O and can leave FTL unresponsive on the RPi3, which trips `chk_pihole` into FAULT. Harmless on a node holding no VIP — and its `10.10.53.53` resolver fallback keeps the list downloads working meanwhile.

> :bulb: This playbook targets **Pi-hole v6**. Key v6 differences:
>
> - Main config: `/etc/pihole/pihole.toml` (replaces legacy dnsmasq conf files)
> - DNS service: `pihole-FTL` — restart with `sudo systemctl restart pihole-FTL`
> - Config CLI: `sudo pihole-FTL --config <key> <value>` (e.g. `sudo pihole-FTL --config misc.etc_dnsmasq_d true`)
> - `/etc/dnsmasq.d/` is **ignored by default** (`misc.etc_dnsmasq_d = false`) — the playbook enables this to allow the `20-k3s.conf` wildcard record
> - `pihole setpassword` replaces v5's `pihole -a -p <password>`

## Upgrading Pi-hole

Always use the upgrade script instead of `pihole -up` directly. Upgrade each node (the script is deployed to both):

```bash
ssh pihole-01 "sudo pihole-upgrade"
ssh pihole-02 "sudo pihole-upgrade"
```

The script handles a circular DNS dependency: Tailscale manages `/etc/resolv.conf` and routes DNS through Pi-hole itself. When `pihole -up` restarts FTL mid-upgrade, DNS breaks and the upgrade can't reach GitHub to finish.

The script:

1. Verifies Unbound is healthy
2. Stops Tailscale (breaks the circular dependency)
3. Sets a temporary DNS fallback (`9.9.9.9`)
4. Runs `pihole -up`
5. Verifies critical settings (`dns.upstreams`, `misc.etc_dnsmasq_d`) and restores them if the upgrade reset them
6. Restarts Tailscale (reclaims `/etc/resolv.conf` automatically)

If the script reports warnings, run the full Ansible playbook to restore all settings:

```bash
ansible-playbook pihole/pihole.yaml
```

## Tailscale

Only **pihole-01** joins the tailnet (`100.100.53.53`) and serves DNS to tailnet devices regardless of physical location. See [docs/tailscale.md](../docs/tailscale.md) for the overall architecture (IP convention, subnet routing, DNS flow).

> :warning: VRRP does not cover the tailnet — if pihole-01 itself dies, tailnet DNS drops (LAN clients still fail over via the VIP). Optional follow-up: join pihole-02 to the tailnet as a fallback Tailscale nameserver.

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
