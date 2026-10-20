# Workstation

Intel i7-11700K on an ASUS ROG STRIX B560-F GAMING WIFI, NVIDIA RTX 3080, and 4× 8 GB DDR4
from two Corsair kits.

| Slots            | Kit                  | Model                |
| ---------------- | -------------------- | -------------------- |
| A-DIMM0, B-DIMM0 | Vengeance RGB PRO    | `CMW16GX4M2C3200C16` |
| A-DIMM1, B-DIMM1 | Vengeance RGB PRO SL | `CMH16GX4M2E3200C16` |

| Device    | Model                    | Size   | Role                                         |
| --------- | ------------------------ | ------ | -------------------------------------------- |
| `nvme0n1` | Corsair MP600 CORE       | 1.8 TB | OS (LUKS + btrfs, Limine, snapper)           |
| `sda`     | WDC WD44PURZ (WD Purple) | 3.6 TB | `md0` member                                 |
| `sdb`     | WDC WD44PURZ (WD Purple) | 3.6 TB | `md0` member — XFS RAID 0, mounted `/mnt/r0` |

## Faulty RAM

One module has a defective region. Memtest86+ fails a ~32 KB window at physical
`0x175ce81d8`–`0x175cefe98` (5.83 GB): every error is single-bit, on bits 58 and 61 only
(`Bits in Error Mask: 2400000000000000`). It is not known which DIMM holds it. On a running
system the faults show up as segfaults across unrelated processes, all with
`si_code=0x80` and `si_addr=0` (a #GP from a non-canonical pointer), plus the occasional
kernel oops.

A kernel parameter marks the page-aligned 64 KB block around the window as reserved, so
the kernel never allocates it:

```
memmap=0x10000%0x175ce0000-1+2
```

`memmap=<size>%<offset>-<oldtype>+<newtype>` changes the range's e820 type from 1 (RAM)
to 2 (reserved). A malformed value is rejected with `-EINVAL`, so a typo cannot take RAM
away.

**Never use the `$` form** (`memmap=0x10000$0x175ce0000`). Shells and boot-loader config
parsers expand `$0x…` as a variable, which leaves a bare `memmap=0x10000` — the kernel
reads that as "64 KB of usable RAM" and the boot hangs with no message. The Limine drop-ins
below are sourced by bash, so the hazard applies there too.

XMP stays **disabled** in the BIOS, so the memory runs at 2133 MT/s. The failing window
was measured at that speed and has not been characterised at 3200 MT/s. Clearing the CMOS
turns XMP back on.

The physical address depends on which slots hold which DIMMs. After moving, adding or
removing a module, derive a new range before relying on this one.

### Applying it

The boot entries are built by `limine-entry-tool`, which reads drop-ins from
`/etc/limine-entry-tool.d/`. The kernel-update hook rebuilds from the same files, so the
parameter carries over to every new kernel.

```bash
echo 'KERNEL_CMDLINE[default]+=" memmap=0x10000%0x175ce0000-1+2"' \
  | sudo tee /etc/limine-entry-tool.d/memmap-badram.conf
sudo limine-mkinitcpio
sudo grep -rl --text 'memmap=0x10000%0x175ce0000-1+2' /boot
```

The `grep` must print at least one file under `/boot` (`limine.conf`, or the UKI when the
command line is baked into it). After rebooting, confirm the hole exists:

```bash
journalctl -b -k | grep 'user: \[mem 0x000000017'
```

The output must show the reserved block, with System RAM resuming right after it:

```
user: [mem 0x0000000175ce0000-0x0000000175ceffff]  device reserved
user: [mem 0x0000000175cf0000-0x000000085fffffff]  System RAM
```

A missing parameter fails silently: the system boots and the crashes come back. Before
blaming the range for a new crash, check that the boot in question carried it —
`journalctl -b -N -k | grep -m1 'Command line:'`. Reading `/proc/iomem` as non-root shows
only zeros, so it proves nothing.

To remove it, delete the drop-in and run `sudo limine-mkinitcpio` again.

### Deriving a new range

1. Boot Memtest86+ with CPU mode set to `SEQ`. Parallel mode prints so many errors to the
   console that it looks frozen.

2. Set the error report mode to the Linux `memmap` list. Tests 0 and 7 are left out of
   that list because they can't pin an exact address.

3. Memtest86+ writes nothing to disk, so photograph the screen.

4. Round the reported span outward to 64 KB boundaries: the start down to a multiple of
   `0x10000`, and the size up to a multiple of `0x10000`.

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
