# Longhorn Distributed Block Storage

## Why Longhorn

Every per-app config PVC uses `local-path` by default, which pins the PVC to whichever node provisioned it. If that node goes down or needs maintenance, the pod cannot reschedule.

Longhorn stores each volume as two replicas across both k3s nodes, so pods can move freely between `k3s-server` and `k3s-node-01` without data loss or manual intervention.

### What runs on Longhorn

Radarr, Sonarr, Prowlarr, Bazarr, Jellyfin, Seerr, Searcharr, AutoBrr, Prismarr, Watchlistarr, Uptime-Kuma.

### What stays pinned (no Longhorn)

| App             | Why pinned                                                        | Storage                                                                    |
| --------------- | ----------------------------------------------------------------- | -------------------------------------------------------------------------- |
| **qBittorrent** | Pinned to `k3s-node-01`; needs local SSD for incomplete downloads | config: `local-path`; incomplete: `hostPath /mnt/ssd/local/qbt-incomplete` |
| **SABnzbd**     | Single-file downloads; already on a 120 Gi `local-path` PVC       | unchanged                                                                  |
| **Plex**        | Pinned to `k3s-server` for AMD GPU transcoding                    | config: `local-path`; transcode: `hostPath /mnt/ssd/local/plex-transcode`  |

The `media-data` NFS PVC (UNAS-4) is untouched — Longhorn is only for app config volumes.

---

## Disk layout

Each node has a 1 TB Kingston SATA SSD at `/dev/sda`, partitioned as:

| Node        | Partition   | Size    | Mount               | Purpose                           |
| ----------- | ----------- | ------- | ------------------- | --------------------------------- |
| k3s-server  | `/dev/sda1` | 300 GB  | `/mnt/ssd/longhorn` | Longhorn data path                |
| k3s-server  | `/dev/sda2` | ~654 GB | `/mnt/ssd/local`    | Plex transcode + future hostPaths |
| k3s-node-01 | `/dev/sda1` | 100 GB  | `/mnt/ssd/longhorn` | Longhorn data path                |
| k3s-node-01 | `/dev/sda2` | ~854 GB | `/mnt/ssd/local`    | qbt incomplete downloads          |

---

## Step 1 — Disk preparation (manual, per node)

Run on each node via SSH. **Verify reboot persistence before moving on** (`sudo reboot`, then `df -h /mnt/ssd/*`).

### k3s-server

```bash
sudo wipefs -a /dev/sda
sudo parted -s /dev/sda mklabel gpt
sudo parted -s -a optimal /dev/sda mkpart longhorn ext4 0% 300GiB
sudo parted -s -a optimal /dev/sda mkpart local    ext4 300GiB 100%
sudo mkfs.ext4 -L longhorn /dev/sda1
sudo mkfs.ext4 -L local    /dev/sda2
sudo mkdir -p /mnt/ssd/longhorn /mnt/ssd/local/plex-transcode
sudo chown 1000:1000 /mnt/ssd/local/plex-transcode

LH_UUID=$(sudo blkid -s UUID -o value /dev/sda1)
LO_UUID=$(sudo blkid -s UUID -o value /dev/sda2)
echo "UUID=$LH_UUID /mnt/ssd/longhorn ext4 defaults,nofail,x-systemd.device-timeout=10s 0 2" | sudo tee -a /etc/fstab
echo "UUID=$LO_UUID /mnt/ssd/local    ext4 defaults,nofail,x-systemd.device-timeout=10s 0 2" | sudo tee -a /etc/fstab

sudo systemctl daemon-reload
sudo mount -a
df -h /mnt/ssd/longhorn /mnt/ssd/local
```

### k3s-node-01

Same commands, with two differences — `300GiB → 100GiB` in both `parted mkpart` lines, and:

```bash
sudo mkdir -p /mnt/ssd/longhorn /mnt/ssd/local/qbt-incomplete
sudo chown 1000:1000 /mnt/ssd/local/qbt-incomplete
```

---

## Setup in k8s

The setup in k8s (k3s) is handled via Ansible + Helm charts.
