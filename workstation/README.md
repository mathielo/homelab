# Workstation

The home workstation (`omy-space`) as part of the homelab: storage,
network and the reinstall procedure. 

| Device    | Model                    | Size   | Role                                         |
| --------- | ------------------------ | ------ | -------------------------------------------- |
| `nvme0n1` | Corsair MP600 CORE       | 1.8 TB | OS (LUKS + btrfs, Limine, snapper)           |
| `sda`     | WDC WD44PURZ (WD Purple) | 3.6 TB | md RAID 0 member                             |
| `sdb`     | WDC WD44PURZ (WD Purple) | 3.6 TB | md RAID 0 member — XFS, mounted `/mnt/r0`    |

## Local RAID 0

`sda` + `sdb` form an mdadm RAID 0 (metadata 1.2) holding one XFS
filesystem at `/mnt/r0`. There is no redundancy and no backup. The array lives entirely on
those two disks, so an OS reinstall leaves it intact as long as the installer is pointed at
`nvme0n1` only.

```bash
sudo pacman -S --needed mdadm xfsprogs
sudo mdadm --assemble --scan
sudo mdadm --detail --scan | sudo tee -a /etc/mdadm.conf
```

The array's metadata name is `spacedora:0`, so on another hostname it assembles as
`/dev/md127` rather than `md0`. The fstab entry mounts it by filesystem UUID, so the
device name doesn't matter.

The mount is the `/mnt/r0` entry in [`.config/etc.fstab`](../.config/etc.fstab).

## Network

`enp4s0` is wired to UDB Homelab (port and VLAN details in
[`ansible/group_vars/workstation.yml`](../ansible/group_vars/workstation.yml)):

- **Untagged, VLAN 10** — DHCP. UniFi holds a fixed-IP reservation for the NIC's MAC at
  `10.10.10.180`, so the host config stays stock NetworkManager.
- **Tagged, VLAN 50** — `enp4s0.50` at `10.10.50.180`, created by
  [`ansible/workstation-vlan.yaml`](../ansible/workstation-vlan.yaml). The UNAS shares and
  k3s-node-02's DAS export allow that address, so the NFS mounts depend on it.

```bash
ansible-playbook -i ansible/workstation.ini ansible/workstation-vlan.yaml
```

The NFS mounts need `nfs-utils`; the entries are in
[`.config/etc.fstab`](../.config/etc.fstab), set up as described in the
[README](../README.md#workstation-mounts).

### Programs with their own DNS resolver

The LAN blocks outbound DNS to anything but Pi-hole (see
[`docs/network.md`](../docs/network.md#firewall-rules)). A program that ignores the system
resolver and queries a hardcoded public server (anti-cheat, DRM, some launchers, containers
started with `--dns`) hangs at startup instead of failing. The signature is
`dig @8.8.8.8 example.com` timing out while `dig example.com` answers.

The workaround on this host is an nftables table that DNATs off-LAN port 53 traffic to the
gateway's resolver. Conntrack rewrites the replies, so the program believes the public
server answered. It lives in its own table, so it coexists with ufw:

```bash
sudo nft -f - <<'EOF'
table ip dns_redirect {
  chain output {
    type nat hook output priority -100;
    ip daddr != { 127.0.0.0/8, 10.0.0.0/8 } udp dport 53 dnat to 10.10.10.1
    ip daddr != { 127.0.0.0/8, 10.0.0.0/8 } tcp dport 53 dnat to 10.10.10.1
  }
}
EOF
```

This does not persist across reboots. Remove it with `sudo nft delete table ip dns_redirect`.

## Tailscale

The workstation is not a tailnet member. It sits on the LAN, and with k3s-server
advertising `10.10.50.0/24`, `--accept-routes` would pull Servers-VLAN traffic into the
tunnel instead of the local VLAN 50 leg. If it ever joins, use `tailscale up` without that
flag — and check that any installer script doing the join doesn't pass it.

## Reinstall

Only `nvme0n1` gets formatted. The local RAID 0 survives as long as the installer never
touches `sda`/`sdb`. The `memmap` exclusion comes first on the new install (see [dotfiles](https://github.com/mathielo/dotfiles) `hosts/omy-space`), then the [dotfiles](https://github.com/mathielo/dotfiles) install. This section is the homelab part around
them.

### After the dotfiles install

Each step depends on the one before it.

1. **Clone homelab and link its SSH hosts.** Then add GitHub's CLI and the homelab shell
   additions:

   ```bash
   git clone git@github.com:mathielo/homelab.git ~/src/homelab
   ln -sf ~/src/homelab/.config/ssh.config ~/.ssh/config.d/homelab
   echo 'source "$HOME/src/homelab/.config/bashrc"' >> ~/.bashrc
   ```

2. **Toolchain:** `./scripts/install.sh`, then `gh auth login`. The script doesn't add you
   to the `docker` group: `sudo usermod -aG docker "$USER"` and log in again for sudoless
   Docker.

3. **VLAN 50 leg:** the [playbook](#network). Run it from the **repo root**: inside
   `ansible/`, `ansible.cfg` turns on the sops vars plugin, which fails without the AGE
   key. Confirm `ip route get 10.10.50.4` goes out `enp4s0.50` and `ip route get 1.1.1.1`
   out `enp4s0`.

4. **Mounts:** assemble the [local array](#local-raid-0), then the fstab entries per the
   [README](../README.md#workstation-mounts). `sudo pacman -S --needed xfsprogs` too.

5. **Restore.** If Claude Code already ran on the new install, back up its fresh
   `~/.claude/settings.json` and `history.jsonl` first and merge rather than overwrite:

   ```bash
   B="/mnt/nas/backups/<date> workstation"
   cp ~/.claude/settings.json /tmp/settings.new.json; cp ~/.claude/history.jsonl /tmp/history.new.jsonl
   rsync -rlptH --info=progress2 --exclude=dot-config.tar.gz "$B/" ~/
   jq -s '.[0] * .[1]' "$B/.claude/settings.json" /tmp/settings.new.json > ~/.claude/settings.json
   cat "$B/.claude/history.jsonl" /tmp/history.new.jsonl > ~/.claude/history.jsonl
   ```

   The memory directories land under the same project slugs as long as the username and
   repo paths are unchanged. Check `kubectl get nodes` works with the restored kubeconfig;
   if it's missing, refetch it:

   ```bash
   mkdir -p -m 700 ~/.kube
   ssh k3s-server sudo cat /etc/k3s/k3s.yaml | sed 's/127.0.0.1/10.10.50.10/' > ~/.kube/config-k3s
   chmod 600 ~/.kube/config-k3s
   ```

6. **UniFi plugins.** They start with `uvx`, so install `uv` first, then the plugins, and
   recreate the password file. The restored `settings.json` already enables them and points
   at that file:

   ```bash
   mise use -g uv
   mkdir -p -m 700 ~/.config/unifi
   op read "op://Private/<m8hl login>/password" > ~/.config/unifi/password && chmod 600 ~/.config/unifi/password
   ```

   In Claude: `/plugin install unifi-network@unifi-plugins` and
   `/plugin install unifi-protect@unifi-plugins`, then restart Claude so it picks up `uvx`
   on its `PATH`. A server that failed to start is cached as failed for 15 minutes, even
   across restarts: `/mcp` → the server → Reconnect retries at once.

7. **Later:** delete the NAS backup after a few weeks.

