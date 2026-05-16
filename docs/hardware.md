# Hardware

All physical devices in the homelab.

## Compute

[CPU Benchmarks](https://www.cpubenchmark.net/compare/5889vs3565vs3301/Intel-i5-14500T-vs-AMD-Ryzen-5-PRO-3400GE-vs-AMD-Ryzen-3-2200GE)

| Host          | Hardware                                                                                                                                                     | CPU                          | RAM            | Storage                                 | VLAN | IP           |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------- | -------------- | --------------------------------------- | ---- | ------------ |
| k3s-server    | [Lenovo ThinkCentre M75q-1](https://www.lenovo.com/us/en/p/desktops/thinkcentre/m-series-tiny/thinkcentre-m75q-1/11tc1mtm73q)                                | Ryzen 5 PRO 3400GE @ 3.30GHz | 32GB DDR4      | 256GB NVMe SSD<br>1TB Kingston SATA SSD | 50   | 10.10.50.10  |
| k3s-node-01   | [Lenovo ThinkCentre M715Q](https://www.lenovo.com/us/en/p/desktops/thinkcentre/m-series-tiny/thinkcentre-m715q-tiny/11tc1mt715q)                             | Ryzen 3 2200GE @ 3.20GHz     | 32GB DDR4      | 256GB NVMe SSD<br>1TB Kingston SATA SSD | 50   | 10.10.50.11  |
| k3s-node-02   | [Lenovo ThinkCentre M70q Gen 5 Tiny](https://www.lenovo.com/us/en/p/desktops/thinkcentre/m-series-tiny/lenovo-thinkcentre-m70q-gen-5-tiny-intel/len102c0052) | Intel Core i5-14500T vPro    | 16GB DDR5 5600 | 2TB Samsung 990 Pro NVMe                | 50   | 10.10.50.12  |
| pihole        | Raspberry Pi 5 Model B                                                                                                                                       | ARM Cortex-A76 (4-core)      | 8GB            | SD card                                 | 53   | 10.10.53.53  |
| homeassistant | Raspberry Pi 5 Model B                                                                                                                                       | ARM Cortex-A76 (4-core)      | 8GB            | SD card                                 | 50   | 10.10.50.123 |

### Workload pinning

- **k3s-server** — Plex (pinned for AMD GPU transcoding)
- **k3s-node-01** — SABnzbd (incomplete downloads on local SATA); also drives the DeskPi 7.84" rack touchscreen as an OS-level kiosk (`ansible/kiosk.yaml`, sandboxed systemd service — does not affect scheduled workloads)
- **k3s-node-02** — qBittorrent clients (incomplete downloads on local NVMe)
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
| `/dev/nvme0n1p3` | 40 GiB   | ext4 | `/`                  | Ubuntu + k3s + container image cache    |
| `/dev/nvme0n1p4` | ~195 GiB | ext4 | `/mnt/nvme/longhorn` | Longhorn distributed block data         |
| `/dev/nvme0n1p5` | ~1.6 TiB | ext4 | `/mnt/nvme/local`    | qBittorrent clients' incomplete/staging |

Longhorn is sized to match the other two nodes once they migrate — replicas stay symmetric. Remaining NVMe space backs the qBt incomplete dirs.

See [Longhorn Storage](storage-longhorn.md) for disk preparation and Longhorn setup details.

## Storage

| Device | Hardware  | Storage                                                                         | VLAN | IP        |
| ------ | --------- | ------------------------------------------------------------------------------- | ---- | --------- |
| UNAS-4 | UniFi NAS | 4 x 24TB 7200RPM HDD (RAID 5, ~72TB usable) + 2x 500GB M.2 SSD read-write cache | 1    | 10.10.1.4 |

## Networking

All UniFi networking equipment lives on VLAN 1 (management). Only the gateway, NVR, and NAS have static IPs; everything else uses DHCP.

| Device          | Model              | IP        |
| --------------- | ------------------ | --------- |
| R18 UGC Max     | UniFi Gateway      | 10.10.1.1 |
| UNVR-I          | UniFi NVR Instant  | 10.10.1.2 |
| USW Lite 8 PoE  | UniFi Switch       | Dynamic   |
| U7 Pro XG       | UniFi AP           | Dynamic   |
| UDB Homelab     | UniFi Dream Bridge | Dynamic   |
| UDB Living Room | UniFi Dream Bridge | Dynamic   |
