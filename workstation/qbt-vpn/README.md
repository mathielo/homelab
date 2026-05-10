# qbt-vpn — qBittorrent behind ProtonVPN on Fedora workstation

Rootless Podman + Quadlet running qBittorrent inside Gluetun's network namespace.
qBt borrows gluetun's netns via `Network=container:gluetun` — it has no
interfaces of its own, so if gluetun dies the netns disappears and qBt loses
all connectivity. That's the killswitch. Gluetun's built-in iptables firewall
is the second layer: only the WG tunnel and explicitly-allowed LAN egress.
Host networking (LAN, Tailscale, Pi-hole) is untouched.

Pattern mirrors `k3s/apps/media/qbittorrent/values.yaml` — same gluetun env,
same NAT-PMP renewal, same `VPN_PORT_FORWARDING_UP_COMMAND` to push the
forwarded port to qBt's API on change.

Deployed by `ansible/qbt-vpn.yaml` against the local workstation.

## Files

| File                    | Role                                                           |
| ----------------------- | -------------------------------------------------------------- |
| `gluetun.container`     | VPN sidecar (ProtonVPN WireGuard, NAT-PMP); owns the netns     |
| `qbittorrent.container` | qBt container; joins gluetun's netns, runs as host UID 1000    |
| `update-qbt-port.sh`    | Pushes the forwarded port to qBt's API on change               |
| `99-qbt-conntrack.conf` | sysctl drop-in for power seeding (high conntrack, file limits) |

The encrypted SOPS file `ansible/qbt-vpn.sops.yaml` holds the WireGuard private
key and address.

## Reproduction (post-format)

### 1. Generate ProtonVPN WireGuard config

ProtonVPN dashboard → WireGuard → new config:

- Platform: Linux
- VPN Accelerator: on
- NAT-PMP (Port Forwarding): **on**
- Moderate NAT: on
- Pick a P2P-flagged server (Sweden or wherever)

Save the `.conf`. You need `PrivateKey` and `Address` lines.

Do **not** reuse the WG config already in k3s — Proton drops the old session
when the same key reconnects elsewhere.

### 2. Encrypt secrets with SOPS

```sh
cd ansible
sops qbt-vpn.sops.yaml
```

Editor opens an empty file; paste:

```yaml
wireguard_private_key: "<PrivateKey from .conf>"
wireguard_addresses: "<Address from .conf, e.g. 10.2.0.2/32>"
```

Save and quit — sops encrypts on save (rules in `.sops.yaml` apply).
Commit the encrypted file.

### 3. Run the playbook

```sh
sudo dnf install -y ansible
ansible-galaxy collection install community.general community.sops
sops-age-key                  # loads SOPS_AGE_KEY from 1Password into env
cd ansible
ansible-playbook qbt-vpn.yaml
```

The playbook is idempotent. It installs podman + flatpak + Podman Desktop,
enables linger, sets the `container_use_devices` SELinux boolean (so rootless
containers can open `/dev/net/tun`), creates dirs, symlinks the Quadlets,
copies the port-update script, places the sysctl drop-in, decrypts the SOPS
file and writes `~/.config/qbt-vpn/secrets.env` (mode 0600), pre-pulls images,
enables the podman user socket, and starts `qbittorrent.service` (which pulls
in `gluetun.service` via `Requires=`).

### 4. qBittorrent first-run setup

`hotio/qbittorrent` 5.x generates a temporary admin password on first start.

```sh
podman logs qbittorrent | grep -i 'temporary password'
```

Open <http://127.0.0.1:8080>, log in with `admin` + that password.

In **Tools → Options → Web UI**:

- Set a permanent password
- Tick **Bypass authentication for clients on localhost**
  (required so gluetun's `UP_COMMAND` can POST the forwarded port without auth)

Restart the stack:

```sh
systemctl --user restart qbittorrent.service
```

Confirm the forwarded port arrived: **Tools → Options → Connection** —
"Port used for incoming connections" should match the port in
`podman logs gluetun | grep 'port forwarded'`.

## Operations

| Action               | Command                                                                                                                  |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Logs                 | `podman logs -f gluetun` / `podman logs -f qbittorrent`                                                                  |
| Restart everything   | `systemctl --user restart qbittorrent.service`                                                                           |
| Stop                 | `systemctl --user stop qbittorrent.service gluetun.service` (BindsTo also stops qBt automatically when gluetun stops)    |
| Verify VPN egress IP | `podman exec gluetun wget -qO- https://ipinfo.io/ip`                                                                     |
| Verify kill switch   | `systemctl --user stop gluetun.service` then check qBt has no connectivity                                               |
| Update images        | Renovate opens a PR; bump `Image=` tag, `systemctl --user daemon-reload && systemctl --user restart qbittorrent.service` |
| Rotate WG key        | `sops ansible/qbt-vpn.sops.yaml`, edit, save, re-run playbook                                                            |
| GUI                  | Launch Podman Desktop (Flatpak) — talks to the user `podman.socket`                                                      |

## Notes

- WebUI bound to `127.0.0.1:8080` only — not reachable from LAN. Use SSH
  port-forward or Tailscale if you need remote access. The port is published
  by `gluetun.container` (it owns the netns); qBt just listens inside it.
- Incomplete downloads land in `~/_qbt` (NVMe). Completed downloads move to
  `/mnt/r0` (HDD RAID). Change the `Volume=` lines in `qbittorrent.container`
  to relocate.
- `UserNS=keep-id:uid=1000,gid=1000` on qBt only — gluetun must stay as root
  in its userns to manage iptables for the WG tunnel.
- `:Z` on bind mounts is required because Fedora has SELinux enforcing.
- This stack runs in parallel with the k3s qBt — different WG keys, different
  Proton sessions, separate torrent libraries.
