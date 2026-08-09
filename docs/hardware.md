# Hardware

All physical devices in the homelab.

## Compute

[CPU Benchmarks](https://www.cpubenchmark.net/compare/5889vs3565vs3301/Intel-i5-14500T-vs-AMD-Ryzen-5-PRO-3400GE-vs-AMD-Ryzen-3-2200GE)

| Host          | Hardware                                                                                                                                                     | CPU                          | RAM            | Storage                                 | VLAN | IP           |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------- | -------------- | --------------------------------------- | ---- | ------------ |
| k3s-server    | [Lenovo ThinkCentre M75q-1](https://www.lenovo.com/us/en/p/desktops/thinkcentre/m-series-tiny/thinkcentre-m75q-1/11tc1mtm73q)                                | Ryzen 5 PRO 3400GE @ 3.30GHz | 32GB DDR4      | 256GB NVMe SSD<br>1TB Kingston SATA SSD | 50   | 10.10.50.10  |
| k3s-node-01   | [Lenovo ThinkCentre M715Q](https://www.lenovo.com/us/en/p/desktops/thinkcentre/m-series-tiny/thinkcentre-m715q-tiny/11tc1mt715q)                             | Ryzen 3 2200GE @ 3.20GHz     | 32GB DDR4      | 256GB NVMe SSD<br>1TB Kingston SATA SSD | 50   | 10.10.50.11  |
| k3s-node-02   | [Lenovo ThinkCentre M70q Gen 5 Tiny](https://www.lenovo.com/us/en/p/desktops/thinkcentre/m-series-tiny/lenovo-thinkcentre-m70q-gen-5-tiny-intel/len102c0052) | Intel Core i5-14500T vPro    | 16GB DDR5 5600 | 2TB Samsung 990 Pro NVMe                | 50   | 10.10.50.12  |
| pihole-01     | Raspberry Pi 5 Model B                                                                                                                                       | ARM Cortex-A76 (4-core)      | 8GB            | SD card                                 | 53   | 10.10.53.51  |
| pihole-02     | Raspberry Pi 3 Model B+                                                                                                                                      | ARM Cortex-A53 (4-core)      | 1GB            | SD card                                 | 53   | 10.10.53.52  |
| homeassistant | Raspberry Pi 5 Model B                                                                                                                                       | ARM Cortex-A76 (4-core)      | 8GB            | SD card                                 | 50   | 10.10.50.123 |

### Workload pinning

- **k3s-server** — no pinned workloads.
- **k3s-node-01** — SABnzbd (incomplete downloads on local SATA). Also drives the DeskPi 7.84" rack touchscreen off DP-2 as an OS-level kiosk (`ansible/kiosk.yaml`, sandboxed systemd service — does not affect scheduled workloads).
- **k3s-node-02** — qBittorrent clients (incomplete downloads on local NVMe) and Plex, pinned together by `nodeSelector`. Has an Intel UHD Graphics 770 iGPU exposed via the Intel device plugin (`gpu.intel.com/i915`), which is what Plex transcodes on.
- Everything else is free to schedule anywhere.

### k3s disk layout

**k3s-server** and **k3s-node-01** each have a 256 GB NVMe (rootfs + Longhorn) and a 1 TB Kingston SATA SSD (node-specific local hostPath).

NVMe layout (identical on both nodes):

| Partition        | Size     | FS   | Mount                | Purpose                              |
| ---------------- | -------- | ---- | -------------------- | ------------------------------------ |
| `/dev/nvme0n1p1` | 1 GiB    | vfat | `/boot/efi`          | Ubuntu boot                          |
| `/dev/nvme0n1p2` | 2 GiB    | ext4 | `/boot`              | Kernel/initramfs                     |
| `/dev/nvme0n1p3` | 40 GiB   | ext4 | `/`                  | Ubuntu + k3s + container image cache |
| `/dev/nvme0n1p4` | ~195 GiB | ext4 | `/mnt/nvme/longhorn` | Longhorn distributed block data      |

SATA SSD layout (node-specific purpose):

| Node        | Partition   | Size     | Mount            | Purpose                      |
| ----------- | ----------- | -------- | ---------------- | ---------------------------- |
| k3s-server  | `/dev/sda1` | ~931 GiB | `/mnt/ssd/local` | Plex transcode hostPath      |
| k3s-node-01 | `/dev/sda1` | ~931 GiB | `/mnt/ssd/local` | SABnzbd incomplete downloads |

**k3s-node-02** has a single 2 TB Samsung 990 Pro NVMe with no SATA SSD. Partitioning:

| Partition        | Size     | FS   | Mount                | Purpose                                 |
| ---------------- | -------- | ---- | -------------------- | --------------------------------------- |
| `/dev/nvme0n1p1` | 1 GiB    | vfat | `/boot/efi`          | Ubuntu boot                             |
| `/dev/nvme0n1p2` | 2 GiB    | ext4 | `/boot`              | Kernel/initramfs                        |
| `/dev/nvme0n1p3` | 80 GiB   | ext4 | `/`                  | Ubuntu + k3s + container image cache    |
| `/dev/nvme0n1p4` | ~195 GiB | ext4 | `/mnt/nvme/longhorn` | Longhorn distributed block data         |
| `/dev/nvme0n1p5` | ~1.6 TiB | ext4 | `/mnt/nvme/local`    | qBittorrent clients' incomplete/staging |

Longhorn is sized to match the other two nodes once they migrate — replicas stay symmetric. Remaining NVMe space backs the qBt incomplete dirs.

**Swap:** k3s-server and k3s-node-01 run swapless — Ubuntu's default 8 GiB `/swap.img` is removed by the `[no_swap]` inventory group in [`ansible/k3s/install-k3s.yaml`](../ansible/k3s/install-k3s.yaml).

See [Longhorn Storage](storage-longhorn.md) for disk preparation and Longhorn setup details.

> **pihole-01 / pihole-02** run Pi-hole in active/standby; clients use the floating keepalived VIP `10.10.53.53` / `::53` (pihole-01 is the normal master). See [ansible/pihole.md](../ansible/pihole.md).

**k3s-node-02 external storage:** a Cenmate 802U3-5G USB-3 2-bay DAS with 2×24 TB 3.5" HDDs in software RAID 0 (mdadm), ext4, mounted at `/mnt/r0` (~43.7 TiB). Provisioned by [`ansible/das-raid.yaml`](../ansible/das-raid.yaml); maintenance via `das-up` / `das-down` on the node (see playbook header), drive swaps via [`docs/das-drive-swap.md`](das-drive-swap.md). The filesystem is built with `-m 0 -T largefile4` — at this size the ext4 defaults would sink ~2.2 TiB into the root reserve and ~190 GB into inode tables. All three `qbt-*` instances plus `qui` mount the DAS root at `/r0` read-write, and `autobrr` mounts it read-only. The marker file `/mnt/r0/.r0-mounted` (placed on the DAS filesystem by the playbook) gates both startup (strict `File` hostPath) and runtime (liveness probe reading it every 30s) — disconnect → pod crashloops → recovers automatically on `das-up`.

## Storage

| Device               | Hardware                           | Storage                                                                          | VLAN | IP         |
| -------------------- | ---------------------------------- | -------------------------------------------------------------------------------- | ---- | ---------- |
| UNAS-4               | UniFi NAS                          | 4 x 24TB 7200RPM HDD (RAID 5, ~72TB usable) + 2x 1TB Intel 660p M.2 SSD lvmcache | 50   | 10.10.50.4 |
| Cenmate 802U3-5G DAS | USB-3 2-bay DAS (ASMT 2115 bridge) | 2 x 24TB HDD (software RAID 0 via mdadm, ~43.7 TiB) — attached to `k3s-node-02`  | -    | -          |

## Networking

UniFi networking equipment lives on VLAN 1 (management). The UNVR-I sits on the
Protect VLAN (20) alongside the cameras, and the UNAS-4 on the Servers VLAN (50)
with the k3s nodes. Static IPs are used for the gateway, NVR, and NAS; everything
else uses DHCP.

| Device              | Model              | IP         |
| ------------------- | ------------------ | ---------- |
| R18 UGC Max         | UniFi Gateway      | 10.10.1.1  |
| UNVR-I              | UniFi NVR Instant  | 10.10.20.2 |
| USW Flex 2.5G 8 PoE | UniFi Switch       | Dynamic    |
| U7 Pro XG           | UniFi AP           | Dynamic    |
| UDB Homelab         | UniFi Dream Bridge | Dynamic    |
| UDB Living Room     | UniFi Dream Bridge | Dynamic    |
