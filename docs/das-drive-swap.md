# DAS Drive Swap (k3s-node-02)

Replacing the disks in the Cenmate 802U3-5G DAS behind `/mnt/r0`. Written for the
2×4 TB → 2×24 TB swap, but the procedure is generic — the array is RAID 0, so any
drive replacement is a destructive rebuild.

**The array holds no redundancy and no backup.** Everything on `/mnt/r0` is gone
the moment the old disks come out. Handle the data before starting.

> :bulb: Powering the enclosure down **without** losing the array — relocating it,
> reseating a cable, improving airflow — is [`das-power-cycle.md`](das-power-cycle.md).
> Steps 1 and 2 below are shared; the bring-up is not.

## What consumes `/mnt/r0`

| Workload  | Namespace | Mount    | ArgoCD app |
| --------- | --------- | -------- | ---------- |
| `qbt-se`  | `media`   | `/r0` rw | `qbt-se`   |
| `qbt-br`  | `media`   | `/r0` rw | `qbt-br`   |
| `qbt-mam` | `media`   | `/r0` rw | `qbt-mam`  |
| `qui`     | `media`   | `/r0` rw | `qui`      |
| `autobrr` | `media`   | `/r0` ro | `autobrr`  |

The three `qbt-*` pods also mount `/mnt/r0/.r0-mounted` as a strict `File`
hostPath and poll it from a liveness probe every 30s — they will crashloop, by
design, the moment the mount goes away. `autobrr` mounts `/mnt/r0` as a strict
`Directory` hostPath and will fail to schedule while the mount is absent.

Nothing else lives on the DAS: Longhorn, the OS, and the qBt incomplete/staging
dirs are all on `nvme0n1`.

## Before you start

- **Torrent state**: every torrent whose content sits under `/r0` will error out
  and need a recheck. If you restore the data to the same paths on the new array,
  they resume after a force-recheck; if you don't, they're gone.
- **Cross-seed hardlinks**: `qui` creates hardlinks under `/r0/cross-seed`. A
  plain copy expands them into full copies — use `rsync -aH` (or `cp -a --link`
  semantics) if you're staging the data somewhere and copying it back.
- **Enclosure capacity**: the ASMedia bridges are the component most likely to
  cap out on large drives. Confirmed good at 24 TB on 2026-07-31 — both bays
  reported the full `24000277250048` bytes. Step 3 re-verifies anyway, since a
  capped bridge reports a truncated size rather than failing outright.

## 1. Quiesce the consumers

Suspend auto-sync on the five apps plus the `media-apps` root (which otherwise
reverts the child patches — see [`pvc-maintenance.md`](pvc-maintenance.md)):

```bash
for app in media-apps qbt-se qbt-br qbt-mam qui autobrr; do
  kubectl -n argocd patch application $app \
    --type=json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
done
```

Scale the workloads to zero and wait for the pods to actually go:

```bash
for d in qbt-se qbt-br qbt-mam qui autobrr; do
  kubectl -n media scale deploy/$d --replicas=0
done

kubectl -n media wait --for=delete pod \
  -l 'app.kubernetes.io/instance in (qbt-se,qbt-br,qbt-mam,qui,autobrr)' --timeout=180s
```

Confirm nothing is left holding the mount (`psmisc`/`fuser` is not installed on
the node — `lsof` is):

```bash
kubectl -n media get pods
ssh k3s-node-02 'sudo lsof +D /mnt/r0 2>/dev/null || echo "no users"'
```

## 2. Take the array down

```bash
ssh k3s-node-02 'sudo das-down'   # umount /mnt/r0 && mdadm --stop /dev/md0
```

### `mdadm --stop` fails with "Cannot get exclusive access"

Seen on the 2026-07-31 swap. The `umount` succeeds (`/mnt/r0 is not a mountpoint`)
but the array won't stop. Note that re-running `das-down` won't help — its
`umount` now fails first under `set -e`. Diagnose in this order:

```bash
# 1. Real holders? (all four should come back empty)
ssh k3s-node-02 'sudo grep -H " 9:0 " /proc/*/mountinfo 2>/dev/null'          # mounts, any namespace
ssh k3s-node-02 'sudo find /proc -maxdepth 3 -regextype posix-extended \
  -regex "/proc/[0-9]+/(fd/[0-9]+|cwd|root)" -lname "*r0*" -printf "%p -> %l\n"'  # open fds
ssh k3s-node-02 'ls /sys/block/md0/holders/'                                   # stacked dm/LVM/partitions
ssh k3s-node-02 'ps -eo pid,cmd | grep "[m]dadm"'                              # mdadm --monitor

# 2. Superblock still live?
ssh k3s-node-02 'ls /sys/fs/ext4/'
```

Search by device number (`9:0`), not by the string `md0` — a bind mount or an
open file inside the filesystem has a path like `/mnt/r0/…` that never matches
`md0`. Also run the `/proc/*/fd` glob under `sudo find`, not `sudo ls -l
/proc/*/fd/*`: the shell expands that glob as your own user and silently skips
every root-owned process.

If all the holder checks are empty but `/sys/fs/ext4/md0` is still listed, ext4's
`put_super()` never ran and the filesystem still claims the device as its
`bd_holder`. There is nothing in userspace left to close. Don't keep chasing it —
just leave the array assembled and pull the power (see below); it costs nothing
here because the filesystem is already detached everywhere and the data is being
destroyed anyway.

### Powering off with the array still assembled

Safe when — and only when — the filesystem is unmounted in every namespace, the
array reads `clean`, and the data is expendable. RAID 0 has no resync state and
an unmounted filesystem has no dirty writeback, so there is nothing to lose.

**The trap is on the way back up.** A stale `md0` left registered in the kernel
makes the playbook's `mdadm --detail {{ md_device }}` pre-check succeed, so the
create play short-circuits and you silently get no new array. Always confirm the
array is really gone before step 4:

```bash
ssh k3s-node-02 'cat /proc/mdstat; sudo mdadm --detail /dev/md0; echo "rc=$?"'
```

Want no `md0` line and a non-zero `rc`. With the member disks unplugged,
`sudo mdadm --stop /dev/md0` usually succeeds on a retry. If it still refuses,
reboot the node **while the DAS is unplugged** — gracefully, with the Longhorn
cordon-and-detach step from [`../scripts/rack/shutdown`](../scripts/rack/shutdown),
since node-02 carries Longhorn replicas and yanking an attached volume corrupts
them.

Verify it's clean before touching hardware — `/proc/mdstat` must list no arrays
and `/mnt/r0` must not be a mountpoint:

```bash
ssh k3s-node-02 'cat /proc/mdstat; mountpoint /mnt/r0 || echo "unmounted OK"; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT /dev/sda /dev/sdb'
```

Then power the DAS off at the enclosure before unplugging it. The `/etc/fstab`
entry is `nofail` with a 30s device timeout, so the node boots fine with the DAS
absent — leave the entry in place.

## 3. Swap the drives and verify the enclosure sees them

Both drives out, both new drives in, power on. Then check three things.

**The bridges came back and the by-id paths are unchanged.** The `by-id` names
encode the _USB bridge_ serial (one bridge per bay), not the disk serial, so they
should survive the swap untouched — the playbook's `das_devices` then needs no
edit:

```bash
ssh k3s-node-02 'lsusb | grep ASMedia; ls -l /dev/disk/by-id/ | grep usb'
```

Expected, unchanged from before the swap:

```
usb-ASMT_2115_ACAAEBBB46E7-0:0 -> ../../sdb
usb-ASMT_2115_ACAAEBBB46E8-0:0 -> ../../sda
```

If a path _did_ change, don't edit the playbook — override at run time in step 4:

```bash
ansible-playbook -i ansible/inventory.ini ansible/das-raid.yaml \
  -e '{"das_devices":["/dev/disk/by-id/usb-<new-a>","/dev/disk/by-id/usb-<new-b>"]}'
```

**The full 24 TB is addressable.** This is the step that catches a bridge LBA
limit — a capped bridge reports a truncated size (2 TB or 16 TB) rather than
failing outright:

```bash
ssh k3s-node-02 'lsblk -o NAME,SIZE,MODEL /dev/sda /dev/sdb; for d in sda sdb; do echo "$d: $(sudo blockdev --getsize64 /dev/$d)"; done'
```

Each disk must read `21.8T` / ~`24000000000000` bytes. Anything smaller means the
enclosure can't address the drive — stop and resolve that before creating the
array.

**Both disks are on the UAS driver**, as before (falling back to `usb-storage`
means degraded throughput and no queueing):

```bash
ssh k3s-node-02 'for d in sda sdb; do echo "$d: $(basename $(readlink -f /sys/block/$d/device/../../../driver))"; done'
```

## 4. Create the new array

The playbook is the whole procedure — it wipes signatures, creates `/dev/md0`,
makes the filesystem, persists the array to `mdadm.conf` + initramfs, rewrites the
`/etc/fstab` entry with the new UUID, mounts it, chowns to `1000:1000`, and drops
the `.r0-mounted` marker back:

```bash
ansible-playbook -i ansible/inventory.ini ansible/das-raid.yaml
```

It prints the target disks and pauses for a typed `GOAHEAD` before wiping. Read
the printed sizes and serials before answering.

Two things the playbook handles that are worth knowing:

- The create play short-circuits if `/dev/md0` already exists. Step 2 stopped the
  array, so it will run — but if you rebooted in between, `mdadm --assemble
--scan` may have brought a stale array back. Re-run `sudo das-down` first.
- Filesystem is built with `-m 0 -T largefile4`. On a 43.7 TiB array the ext4
  defaults would sink ~2.2 TiB into the root reserve and ~190 GB into inode
  tables; this array holds large media files, so both are pure waste. Reclaims
  roughly 2.4 TiB.

## 5. Verify

```bash
ssh k3s-node-02 'df -h /mnt/r0; cat /proc/mdstat; ls -la /mnt/r0/.r0-mounted; findmnt /mnt/r0'
```

Expect ~`44T` size with near-zero used, `md0 : active raid0` over both disks, and
the marker owned by `1000:1000`. Confirm the fstab entry now carries the new UUID:

```bash
ssh k3s-node-02 'grep r0 /etc/fstab; sudo blkid -s UUID -o value /dev/md0; grep -A1 "ANSIBLE-MANAGED DAS-RAID" /etc/mdadm/mdadm.conf'
```

Reboot-safety check (optional but cheap, and the failure mode is a node that
comes up without its scratch array):

```bash
ssh k3s-node-02 'sudo das-down && sudo das-up && df -h /mnt/r0'
```

## 6. Resume the workloads

```bash
for app in qbt-se qbt-br qbt-mam qui autobrr media-apps; do
  kubectl -n argocd patch application $app --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'
done
```

Argo scales the deployments back to 1. Watch that the `qbt-*` pods clear their
liveness probe rather than crashlooping (which would mean the marker is missing):

```bash
kubectl -n media get pods -w
```

## 7. Update the repo

Sizes are documented in several places and all of them go stale on a capacity
change:

- [`hardware.md`](hardware.md) — the `k3s-node-02 external storage` paragraph and
  the storage table row
- [`storage-longhorn.md`](storage-longhorn.md) — the `/mnt/r0` mount table row
- [`../ansible/das-raid.yaml`](../ansible/das-raid.yaml) — header comment
- [`../k3s/apps/media/qbt/values-common.yaml`](../k3s/apps/media/qbt/values-common.yaml)
  — the `persistence.r0` comment

No change needed to the Prometheus rules (`/mnt/r0` is excluded from the 85/90%
alerts and has its own 98% safety net, all size-independent) or to autobrr's
`disk-guard.sh` — its 500 GiB floor still covers in-flight NVMe staging.
