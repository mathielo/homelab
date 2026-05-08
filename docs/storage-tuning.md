# Storage / I/O Tuning

Host-level kernel and mount tuning to keep slow remote storage (NFS to UNAS-4)
from cascading into node-wide stalls, and to deepen block-layer queues on
co-tenanted local SSDs.

Applied by `ansible/host-tuning.yaml`.

## Why these tunings exist

A `qBittorrent` move from local SSD to the NFS Media share would cause the
entire k3s-node-01 to feel sluggish — kubelet, container runtime, and even
unrelated local writes would stall for seconds at a time. Investigation
showed the bottleneck was not a single component but a three-layer
amplifier:

1. **NAS:** RAID 5 destage + nearly-full SSD write cache → NFS write `exec`
   times of 3–4 seconds.
2. **Kernel:** NFS BDI default `max_ratio=100` plus `vm.dirty_ratio=20` let
   the slow NFS mount fill up to ~6 GB of RAM with dirty pages. When the
   global dirty threshold is hit, Linux **synchronously throttles every
   writer** on the node — including local-disk writers that have nothing to
   do with NFS.
3. **Local SSD:** the Kingston OCP0S31 (DRAMless OEM SATA SSD) hosts both
   Longhorn replicas (`sda1`) and qBt's incomplete directory (`sda2`).
   Default `nr_requests=64` fills immediately under multi-tenant write
   load, queuing reads behind writes.

The tunings address layers 2 and 3. Layer 1 (NAS) is addressed separately
in the UNAS-4 cache configuration.

## What gets applied

### All k3s nodes

| Setting                     | Default       | Tuned     | Where                                    |
| --------------------------- | ------------- | --------- | ---------------------------------------- |
| `vm.dirty_background_ratio` | 10            | 5         | `/etc/sysctl.d/99-storage-tuning.conf`   |
| `vm.dirty_ratio`            | 20            | 15        | same                                     |
| Virtual BDI `max_ratio`     | 100           | 30        | `/etc/udev/rules.d/60-nfs-bdi-cap.rules` |
| `smartmontools`             | not installed | installed | apt                                      |

The udev rule matches `KERNEL=="0:*"` under the `bdi` subsystem, which
covers all virtual backing devices (NFS, FUSE). Local block devices have
their own BDIs (`8:0`, `259:0`, etc.) and are not affected.

### k3s-node-01 only

| Setting                   | Default             | Tuned               | Where                                            |
| ------------------------- | ------------------- | ------------------- | ------------------------------------------------ |
| `sda` `nr_requests`       | 64                  | 256                 | `/etc/udev/rules.d/60-kingston-ssd-tuning.rules` |
| `/mnt/ssd/longhorn` mount | `relatime,commit=5` | `noatime,commit=60` | `/etc/fstab`                                     |
| `/mnt/ssd/local` mount    | `relatime,commit=5` | `noatime,commit=60` | `/etc/fstab`                                     |

`noatime` eliminates atime metadata writes triggered by reads (significant
under 200 active torrents + Longhorn replica scans). `commit=60` lets ext4
coalesce 12× more journal activity before forcing a flush. The data-loss
window on crash grows to 60 s, which is acceptable: Longhorn has its own
replication and qBt re-fetches any unfinished pieces.

The udev rule keys on `ENV{ID_MODEL}=="KINGSTON_OCP0S31"` rather than
`KERNEL=="sda"` so it only applies to this specific drive — if hardware
changes, the rule becomes a no-op rather than mis-tuning a different disk.

## Verifying after apply

```bash
# Sysctl
sysctl vm.dirty_background_ratio vm.dirty_ratio

# NFS BDIs (one entry per active NFS mount)
for f in /sys/class/bdi/0:*/max_ratio; do echo "$f = $(cat $f)"; done

# Block-layer queue (k3s-node-01)
cat /sys/block/sda/queue/nr_requests

# Mount options (k3s-node-01)
findmnt /mnt/ssd/local /mnt/ssd/longhorn -o TARGET,OPTIONS
```

## Rollback

Remove the dropped files and reload:

```bash
sudo rm /etc/sysctl.d/99-storage-tuning.conf
sudo rm /etc/udev/rules.d/60-nfs-bdi-cap.rules
sudo rm /etc/udev/rules.d/60-kingston-ssd-tuning.rules    # node-01 only
sudo sysctl --system
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=bdi --subsystem-match=block
```

Mount option rollback requires editing `/etc/fstab` to restore the original
`defaults,nofail,x-systemd.device-timeout=10s` entries and remounting.
