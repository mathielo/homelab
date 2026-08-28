# Longhorn Distributed Block Storage

Longhorn stores each app config/data volume as 2 replicas across the three k3s nodes, so pods move freely between nodes without data loss. It is the sole default StorageClass. The 50 TB `media-data` NFS PVC (UNAS-4) is **not** on Longhorn — Longhorn is config volumes only.

## What stays pinned (not on Longhorn)

These apps keep their config on Longhorn but use a node-local `hostPath` for hot/scratch data:

| App         | Pinned to     | Local path                                       |
| ----------- | ------------- | ------------------------------------------------ |
| **qbt-br**  | `k3s-node-02` | `/mnt/nvme/local/qbt-br` → `/local`              |
| **qbt-se**  | `k3s-node-02` | `/mnt/nvme/local/qbt-se` → `/local`              |
| **SABnzbd** | `k3s-node-01` | `/mnt/ssd/local/sabnzbd-incomplete` (incomplete) |
| **Plex**    | `k3s-server`  | `/mnt/ssd/local/plex` (transcode; AMD GPU)       |

## Disk layout

Longhorn data lives on each node's NVMe at `/mnt/nvme/longhorn`. A separate local partition holds the pinned workloads above.

| Node        | Mount                | Purpose                           |
| ----------- | -------------------- | --------------------------------- |
| k3s-server  | `/mnt/nvme/longhorn` | Longhorn data (~195 GiB)          |
| k3s-server  | `/mnt/ssd/local`     | Plex transcode (~931 GiB)         |
| k3s-node-01 | `/mnt/nvme/longhorn` | Longhorn data (~195 GiB)          |
| k3s-node-01 | `/mnt/ssd/local`     | SABnzbd incomplete (~931 GiB)     |
| k3s-node-02 | `/mnt/nvme/longhorn` | Longhorn data (~195 GiB)          |
| k3s-node-02 | `/mnt/nvme/local`    | qBt incomplete/staging (~1.6 TiB) |
| k3s-node-02 | `/mnt/r0`            | 2×24 TB HDD RAID 0 (DAS)          |

Partitions are set at OS install. See [Hardware](hardware.md) for the full table.

## Install

```bash
ansible-playbook ansible/k3s/install-k3s.yaml   # open-iscsi + iscsid + rpc-statd (prereqs)
ansible-playbook ansible/k3s/longhorn.yaml      # Helm install, patch BackupTarget, set default SC
```

The second playbook patches the `default` BackupTarget CR with the NFS URL and drops the `is-default-class` annotation from `local-path`. Verify:

```bash
kubectl -n longhorn-system get nodes.longhorn.io   # all READY=True, SCHEDULABLE=True
kubectl get sc                                     # longhorn (default), local-path (not)
```

UI: `https://lh.m6o.dev`.

## hostPath prep (after first boot, per node)

`hostPathType: DirectoryOrCreate` auto-creates dirs as `root:root`, which the `1000:1000` containers can't write to — the `chown` is mandatory:

```bash
# k3s-server
sudo mkdir -p /mnt/ssd/local/plex && sudo chown 1000:1000 /mnt/ssd/local/plex
# k3s-node-01
sudo mkdir -p /mnt/ssd/local/sabnzbd-incomplete && sudo chown 1000:1000 /mnt/ssd/local/sabnzbd-incomplete
# k3s-node-02
sudo mkdir -p /mnt/nvme/local/qbt-br /mnt/nvme/local/qbt-se && sudo chown 1000:1000 /mnt/nvme/local/qbt-*
```

# Backups

Target: the dedicated `k3s` NFS share on UNAS-4 (NFSv3 forced; UNAS only exports v3):

```
nfs://10.10.50.4:/var/nfs/shared/k3s?nfsOptions=vers=3,nolock,actimeo=1,soft,timeo=300,retry=2,retrans=5
```

Set in `ansible/k3s/files/longhorn.values.yaml`, patched onto the `default` BackupTarget CR by the Ansible playbook.

## Schedule & retention

Recurring jobs are GitOps in `k3s/apps/longhorn/recurring-jobs.yaml` (Argo app `longhorn-config`). Every volume auto-enrolls via the `default` group label. Retention is tiered (GFS) so corruption found late is still recoverable:

| Job              | Task     | Cron          | Fires (local)  | Retain | Window    |
| ---------------- | -------- | ------------- | -------------- | ------ | --------- |
| `snapshot-6h`    | snapshot | `0 */6 * * *` | every 6h       | 8      | ~2 days   |
| `daily-backup`   | backup   | `0 1 * * *`   | 01:00          | 14     | 2 weeks   |
| `weekly-backup`  | backup   | `0 2 * * 0`   | Sun 02:00      | 8      | ~2 months |
| `monthly-backup` | backup   | `0 3 1 * *`   | 1st 03:00      | 6      | 6 months  |

Cron is **local time** (Europe/Stockholm), not UTC: Longhorn renders each job into a
k8s CronJob with no `timeZone`, so it inherits the controller-manager's clock. A run
therefore carries a UTC timestamp two hours earlier — 01:00 local is `23:00Z`.

`concurrency` is per-job, not global. Backup jobs scheduled close together each open
their own serialized NFS stream, and the combined write rate is what pushes the soft
mount past its timeout budget; the hour of separation above is what keeps them from
overlapping, since a full daily pass over every volume takes 10–35 min.

Each retained backup is an independent restore point — new ones don't overwrite old ones; the oldest in each tier rolls off. Snapshots are on-cluster and fast but live on the volume's own replicas, so they cover logical mistakes, **not** disk loss.

> Block-level backups copy whatever is on disk, including corruption. When recovering from corruption, restore a tier from **before** the incident and verify before trusting it (see below).

## Inspecting backups

```bash
kubectl -n longhorn-system get backupvolumes
kubectl -n longhorn-system get backups.longhorn.io -l backup-volume=<pv-name>
kubectl -n longhorn-system get backup <name> -o jsonpath='{.status.url}'   # restore URL
```

Or UI → **Backup**.

# Recovery

For the Argo suspend/scale and PV pre-bind mechanics, follow [`pvc-maintenance.md`](pvc-maintenance.md) — it owns the two-tier app suspend and the restore-into-original-PVC-name flow. The Longhorn-specific cases below build on it.

## Restoring a volume from backup

`pvc-maintenance.md` → "Restoring a Longhorn-backed PVC from backup" covers the full flow: suspend Argo, restore the backup into a Longhorn `Volume` (`fromBackup: <url>`), pre-claim a PV to the original PVC name, re-enable Argo.

## Corrupted volume (data intact on disk, but damaged)

Symptoms: pod `CrashLoopBackOff` with app errors like `database disk image is malformed` / `file is corrupt`, **or** pod stuck `ContainerCreating` with `MountVolume.MountDevice failed ... fsck ... UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY`.

1. **Suspend Argo + scale the workload to 0** (per `pvc-maintenance.md`) to release the volume.

2. **If the filesystem won't mount** (kubelet `fsck` aborted), repair it manually. Attach the volume with no workload by adding a ticket to its VolumeAttachment, so you get a stable block device and no CSI mount loop:

   ```bash
   PV=<pvc-volume-name>; NODE=k3s-node-01
   kubectl -n longhorn-system patch volumeattachments.longhorn.io $PV --type=merge \
     -p "{\"spec\":{\"attachmentTickets\":{\"fsck\":{\"id\":\"fsck\",\"nodeID\":\"$NODE\",\"type\":\"longhorn-api\",\"parameters\":{\"disableFrontend\":\"false\"}}}}}"
   # wait until state=attached, then on $NODE:
   ssh $NODE 'sudo dd if=/dev/longhorn/'$PV' bs=4M status=none | gzip -1 > /var/tmp/'$PV'.img.gz'  # insurance
   ssh $NODE 'sudo e2fsck -fy /dev/longhorn/'$PV''                                                  # repair
   kubectl -n longhorn-system patch volumeattachments.longhorn.io $PV --type=json \
     -p '[{"op":"remove","path":"/spec/attachmentTickets/fsck"}]'                                   # detach
   ```

   A pod stuck retrying `MountVolume.MountDevice` is already holding the volume attached with nothing mounted on it, so `/dev/longhorn/$PV` is directly `e2fsck`-able without the ticket. Confirm with `ssh $NODE 'mount | grep $PV'` returning nothing before touching it.

   `e2fsck -y` resolves multiply-claimed blocks by cloning the shared block into one of the claimants, so expect one of the two files to come out wrong even though the filesystem is then clean. Check which files were named in the `fsck` output and treat them as lost.

3. **Assess the data.** Mount the volume in a throwaway pod (`alpine`, `apk add sqlite`) over its PVC and check, e.g. `sqlite3 /config/<app>.db "PRAGMA integrity_check;"`. `fsck` fixes the filesystem, not file contents — an SQLite DB can still be malformed.

4. **If the DB itself is unrecoverable** (`.recover` can't rebuild the tables): restore the newest **pre-incident** backup tier to a temp Longhorn volume, mount it alongside, verify (`integrity_check` = `ok` + sane row counts), checkpoint any WAL, then copy the clean DB into the live (repaired) PVC. Keep the app's existing `config.toml`/secrets.

5. **Re-enable Argo.** The workload scales back and starts on good data.

> `.arr` apps (Sonarr/Radarr/Prowlarr) keep their own nightly backups under `/config/Backups` and auto-restore on a corrupt-DB start, so they usually self-heal. autobrr and similar do **not** — they need the flow above.

## Accidentally-deleted PVC

`reclaimPolicy: Delete` means deleting a PVC also deletes its PV and Longhorn volume. The manifest is still in git, so Argo recreates the PVC — empty. Recover by restoring the latest backup and pre-binding it to the original PVC name: see [`pvc-maintenance.md`](pvc-maintenance.md). Suspend Argo **first**, or it binds the empty PVC to a fresh blank volume before you can intervene.

# Operational notes

## Reboot nodes serially

2 replicas across 3 nodes with strict anti-affinity (`replicaSoftAntiAffinity: false`) means losing one node degrades ~⅔ of volumes, which Longhorn rebuilds onto the spare node automatically. But **reboot one node at a time**, waiting for `Healthy` between reboots — taking down two nodes can drop both replicas of a volume placed on that pair.

```bash
kubectl -n longhorn-system get volumes | grep -v Healthy   # empty = safe to reboot
```

> A simultaneous/unclean shutdown can tear iSCSI volumes away mid-write and corrupt them. `make shutdown` (`scripts/rack/shutdown`) detaches every Longhorn volume first (cordon → scale workloads to 0 → wait for `detached`) before powering off; `make startup` (`scripts/rack/startup`) uncordons on the way back. Don't power the nodes off by other means without detaching first.

## Kernel updates

Unattended-upgrades installs security updates on every host, but reboots only hosts that define `unattended_reboot_time` in `host_vars`. The k3s nodes define none, because an unattended reboot is exactly the "other means" above: it powers the node down with Longhorn volumes still attached — no cordon, no scale-down, no wait for `detached`.

The damage lands on ext4 metadata on the attached volumes and can stay latent for days, until something forces an `fsck` at mount time and the pod fails to start. A node that rebooted and came back up serving traffic is therefore not evidence that the reboot was safe.

A node due for a kernel reboot is marked by `/var/run/reboot-required`; `/cluster-health` reports it. Clear it with `make shutdown` / `make startup`, which detach first.

```bash
for h in k3s-server k3s-node-01 k3s-node-02; do
  echo "$h: $(ssh $h 'cat /var/run/reboot-required.pkgs 2>/dev/null | tr "\n" " " || echo none')"
done
```

## Settings drift

`defaultSettings` in `longhorn.values.yaml` only applies on **first install**. Change a running setting in the UI or patch the CR:

```bash
kubectl -n longhorn-system patch setting <name> --type merge -p '{"value":"<v>"}'
```

# Troubleshooting

**Replica scheduling failures** — Longhorn needs ≥2 schedulable nodes for 2 replicas.

```bash
kubectl -n longhorn-system get replicas | grep -v Running
kubectl -n longhorn-system get nodes.longhorn.io           # SCHEDULABLE=False? check disk
ssh <node> 'df -h /mnt/nvme/longhorn'
```

**Multipath conflict** (`mke2fs ... apparently in use`) — `multipathd` wraps Longhorn's iSCSI LUN, so `mkfs` on a new volume fails (existing volumes are unaffected). `ssh <node> 'sudo multipath -ll'` shows an `mpath*` entry for `IET,VIRTUAL-DISK`. Fixed by the `IET` blacklist in `/etc/multipath.conf`, installed by `ansible/k3s/longhorn.yaml`.

**iscsid inactive** — `ssh <node> 'systemctl is-active iscsid'`; `sudo systemctl start iscsid` (permanent fix in `install-k3s.yaml`).

**Backup target errors** — `kubectl -n longhorn-system get backuptarget default -o yaml | grep -A5 conditions`:

- `rpc.statd is not running` → `sudo systemctl start rpc-statd` (permanent fix in `install-k3s.yaml`)
- `No such file or directory` → URL path must be the export root, not a subdirectory
- `remote share not in 'host:dir' format` → URL needs the colon: `nfs://host:/path`
- `failed to write data during saving blocks: close ...` → the `soft` mount hit its
  timeout budget mid-write and returned EIO, failing one volume while the rest of the
  run succeeds. Which volume loses is probabilistic — larger volumes hold the mount
  longer and so fail more often, but small ones are not exempt. The driver is
  concurrent NFS write pressure, so the levers are the schedule (keep backup jobs off
  each other and out of SAB's 22:00–00:30 drain) and `retrans=5` on the backup target,
  which widens the budget. `hard` would remove the limit entirely but risks an
  unkillable D-state wedge on the NAS mount.

**Silently skipped volumes** — a recurring-job pod reports `Completed` even when
individual volumes inside it errored, and `longhorn_volume_last_backup_at` stays green
for every volume that did succeed. `LonghornVolumeBackupStale` only notices ~8h later,
at 30h. The direct signal is the Backup CR state:

```bash
kubectl get backups.longhorn.io -n longhorn-system -o json \
  | jq -r '.items[]|select(.status.state=="Error")|"\(.metadata.creationTimestamp)\t\(.status.error[0:160])"'
```

A day's volume *count* can also match while the *set* differs, so diff consecutive
days to name what was dropped. Bucket by **local** date: the jobs run 01:00 local,
which is `23:00Z` the previous day, so a UTC bucket puts every nightly backup in the
day before and makes the current day look empty.

```bash
day() { kubectl get backups.longhorn.io -n longhorn-system -o json \
  | jq -r '.items[]|"\(.status.snapshotCreatedAt)\t\(.status.volumeName)"' \
  | while read -r ts vol; do [ "$(date -d "$ts" +%F)" = "$1" ] && echo "$vol"; done | sort -u; }
comm -23 <(day "$(date -d yesterday +%F)") <(day "$(date +%F)")
```

**Prometheus `longhorn` targets refused on :9500** — the chart's
`networkPolicies.restrictInternalTraffic` (default `true` since 1.12.1, and gated
independently of `networkPolicies.enabled`) renders NetworkPolicies that admit only
Longhorn's own components to `longhorn-manager:9500`. The scrape is refused, `up` goes
0 for all three managers, and every Longhorn alert rule goes blind while looking
healthy. `ansible/k3s/files/longhorn.values.yaml` sets it to `false`; confirm with
`kubectl get networkpolicy -n longhorn-system` returning nothing.

**Degraded volume / stopped replica** — Longhorn rebuilds automatically; force it by deleting the stopped replica:

```bash
kubectl -n longhorn-system get replicas -o wide
kubectl -n longhorn-system delete replica <stopped-replica-name>
```
