# DAS Power Cycle (k3s-node-02)

Taking the Cenmate 802U3-5G DAS behind `/mnt/r0` off power **without destroying the
array** — relocating the enclosure, reseating a cable, swapping the PSU, improving
airflow. The data survives.

For replacing the disks, read [`das-drive-swap.md`](das-drive-swap.md) instead — that
procedure is destructive and rebuilds the array from scratch.

> :warning: **Never run `ansible/das-raid.yaml` as part of this procedure.** It wipes
> signatures and creates a fresh array. Bringing the array back here is `sudo das-up`,
> nothing more.

**k3s-node-02 itself stays up.** The DAS is USB-attached and holds nothing the OS or
Longhorn needs — Longhorn replicas and the qBt staging dirs live on `nvme0n1`. Leaving
the node running avoids the Longhorn iSCSI-teardown corruption that a node reboot has to
guard against (see [`../scripts/rack/shutdown`](../scripts/rack/shutdown)).

> If the node is going down too — a full-rack shutdown — run
> [`../scripts/rack/shutdown`](../scripts/rack/shutdown) instead of this runbook's
> steps 1–2. It drains the consumers and runs `das-down` itself. Rejoin this runbook
> at [step 3](#3-power-off-and-move-it) for the enclosure, and at
> [step 4](#4-power-on-and-verify-the-enclosure) on the way back — with
> [`../scripts/rack/startup`](../scripts/rack/startup) in place of step 6, since Argo
> restores the workloads once the nodes are uncordoned.

## What consumes `/mnt/r0`

| Workload  | Namespace | Mount    | ArgoCD app |
| --------- | --------- | -------- | ---------- |
| `qbt-se`  | `media`   | `/r0` rw | `qbt-se`   |
| `qbt-br`  | `media`   | `/r0` rw | `qbt-br`   |
| `qbt-mam` | `media`   | `/r0` rw | `qbt-mam`  |
| `qui`     | `media`   | `/r0` rw | `qui`      |
| `autobrr` | `media`   | `/r0` ro | `autobrr`  |

The three `qbt-*` pods also mount `/mnt/r0/.r0-mounted` as a strict `File` hostPath and
poll it from a liveness probe every 30s — they crashloop, by design, the moment the mount
goes away. `autobrr` mounts `/mnt/r0` as a strict `Directory` hostPath and fails to
schedule while it is absent. Both are why the workloads come down _before_ the array does.

## Pick the moment

Check the move queue is empty and nothing is mid-recheck:

```bash
for p in $(kubectl get pods -n media -o name | grep -E 'qbt-(se|br|mam)' | cut -d/ -f2); do
  echo "--- $p ---"
  kubectl exec -n media $p -c main -- wget -qO- 'localhost:8080/api/v2/torrents/info' 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  moving=%d  checking=%d' % (len([t for t in d if t['state']=='moving']),
                                    len([t for t in d if 'check' in t['state']])))"
done
```

A non-empty queue is not a blocker — qBittorrent re-enqueues on restart. But an
interrupted move can leave a partial file at the destination and cost a force-recheck, so
a quiet window is cheaper. Seeding stops for the duration; everything under `/r0` is
unavailable until the array is back.

## 1. Quiesce the consumers

Suspend auto-sync on the five apps plus the `media-apps` root, which otherwise reverts
the child patches (see [`pvc-maintenance.md`](pvc-maintenance.md)):

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

Confirm nothing is left holding the mount (`psmisc`/`fuser` is not installed on the node
— `lsof` is):

```bash
kubectl -n media get pods
ssh k3s-node-02 'sudo lsof +D /mnt/r0 2>/dev/null || echo "no users"'
```

## 2. Take the array down

```bash
ssh k3s-node-02 'sudo das-down'   # umount /mnt/r0 && udevadm settle && mdadm --stop /dev/md0
```

Verify it is really gone — `/proc/mdstat` must list no arrays and `/mnt/r0` must not be a
mountpoint:

```bash
ssh k3s-node-02 'cat /proc/mdstat; mountpoint /mnt/r0 || echo "unmounted OK"'
```

If `mdadm --stop` fails with "Cannot get exclusive access", work through the holder
checks in
[`das-drive-swap.md`](das-drive-swap.md#mdadm---stop-fails-with-cannot-get-exclusive-access).
Unlike the swap procedure, **do not fall back to pulling the power with the array still
assembled** — that path is only safe when the data is expendable.

### Predicting the "exclusive access" failure

A dozen mount namespaces legitimately carry `/dev/md0` even with every workload stopped:
the `longhorn` and `node-exporter` DaemonSets bind-mount the host root, and systemd
sandboxes services like `systemd-resolved`, `polkitd` and `udevd` into their own
namespaces. **Their presence is not the problem — their propagation type is.**

Slave mounts (`master:N`) receive the host's `umount` and release the device with it.
A _private_ mount holds an independent reference and is what leaves the device busy:

`9:0` below is `/dev/md0`'s device number — confirm with `ls -l /dev/md0` if the array
was ever recreated. One line per mount namespace:

```bash
ssh k3s-node-02 'sudo bash -s' <<'EOF'
for p in $(grep -l " 9:0 " /proc/*/mountinfo 2>/dev/null | grep -oE "[0-9]+"); do
  ns=$(readlink /proc/$p/ns/mnt 2>/dev/null) || continue
  flag=$(grep " 9:0 " /proc/$p/mountinfo 2>/dev/null | head -1 |
         sed -E 's/.* (shared:[0-9]+|master:[0-9]+)? - ext4.*/\1/')
  [ -z "$flag" ] && flag=PRIVATE
  printf '%-16s %-14s %s\n' "$ns" "$flag" "$(cat /proc/$p/comm 2>/dev/null)"
done | sort -u -k1,1
EOF
```

Want exactly one `shared:N` (the host) and every other line `master:N` on that same
number — a healthy node shows around a dozen, all slaves. Any `PRIVATE` line names the
process to remove before retrying; grepping for an open file will not find it, because a
passive mount holds the device without holding a single file descriptor.

## 3. Power off and move it

Power the enclosure off at its own switch _before_ unplugging anything. Then move it.

The `/etc/fstab` entry is `nofail` with a 30s device timeout, so the node stays healthy
with the DAS absent and would boot fine without it. Leave the entry in place.

Airflow is the reason for most trips to this runbook — the drives sit above their 60 °C
maximum operating temperature in the default position. Give the enclosure clear space on
all sides and confirm its fan is unobstructed.

## 4. Power on and verify the enclosure

Power on, then check the bridges came back and both disks present their full capacity:

```bash
ssh k3s-node-02 'lsusb | grep ASMedia; ls -l /dev/disk/by-id/ | grep usb'
ssh k3s-node-02 'lsblk -o NAME,SIZE,MODEL /dev/sda /dev/sdb; for d in sda sdb; do echo "$d: $(sudo blockdev --getsize64 /dev/$d)"; done'
```

Each disk must read `21.8T` / `24000277250048` bytes. A capped bridge reports a truncated
size rather than failing outright.

Confirm both are on the UAS driver — falling back to `usb-storage` means degraded
throughput and no command queueing:

```bash
ssh k3s-node-02 'for d in sda sdb; do echo "$d: $(basename $(readlink -f /sys/block/$d/device/../../../driver))"; done'
```

> :bulb: `sda`/`sdb` may swap between the two bays across a power cycle, and that is
> harmless: mdadm assembles by superblock UUID and `/etc/fstab` mounts by filesystem
> UUID. Nothing here is keyed to the device letter.

## 5. Bring the array back

The array definition lives in `/etc/mdadm/mdadm.conf` and the initramfs, so udev
generally **re-assembles `md0` on its own** the moment the enclosure is plugged back in —
check before doing anything:

```bash
ssh k3s-node-02 'cat /proc/mdstat; mountpoint /mnt/r0 || echo "not mounted"'
```

If `md0` is already active, the only remaining step is the mount:

```bash
ssh k3s-node-02 'sudo mount /mnt/r0'
```

`das-up` works too, but it runs `mdadm --assemble --scan` under `set -e`; with the array
already assembled that step has nothing to do, and a non-zero return would abort the
script before it reaches the mount. Use it only when `/proc/mdstat` is empty:

```bash
ssh k3s-node-02 'sudo das-up'   # mdadm --assemble --scan && mount /mnt/r0
```

Before mounting, confirm the array is whole and the filesystem is the one you left:

```bash
ssh k3s-node-02 'sudo mdadm --detail /dev/md0 | grep -E "State|Active Devices|Failed"; sudo blkid /dev/md0'
```

Want `State : clean`, `Active Devices : 2`, `Failed Devices : 0`, and a filesystem UUID
matching the `/etc/fstab` entry.

Verify the array is complete and the marker the qBt liveness probes need is present:

```bash
ssh k3s-node-02 'cat /proc/mdstat; df -h /mnt/r0; ls -la /mnt/r0/.r0-mounted; findmnt /mnt/r0'
```

Want `md0 : active raid0 sdb[1] sda[0]`, ~`44T` with the **used figure unchanged from
before the move**, and the marker owned by `1000:1000`. A used figure near zero means a
fresh filesystem, not your data — stop and do not let the workloads start.

## 6. Resume the workloads

```bash
for app in qbt-se qbt-br qbt-mam qui autobrr media-apps; do
  kubectl -n argocd patch application $app --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'
done
```

Argo scales the deployments back to 1. Watch that the `qbt-*` pods clear their liveness
probe rather than crashlooping, which would mean the marker is missing:

```bash
kubectl -n media get pods -w
```

Torrents whose move was interrupted re-enqueue on their own; any that error out need a
force-recheck.
