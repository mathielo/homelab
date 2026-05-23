# Longhorn Distributed Block Storage

## Why Longhorn

Longhorn stores each volume as two replicas spread across the three k3s nodes, so pods can move freely between `k3s-server`, `k3s-node-01`, and `k3s-node-02` without data loss or manual intervention.

This also enables for HA should services require more than one replica.

### What runs on Longhorn

All pods have their config + data set in Longhorn PVCs. A few services have some extra mounts for specific purposes:

- qBittorrent + SABnzbd: local SSD mount for ongoing downloads
- Plex: local SSD mount for active transcode
- Emby: local NVMe mount for active transcode

### What stays pinned (not on Longhorn)

| App             | Why pinned                                                                      | Storage                                                                                    |
| --------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| **qbt-br**      | Pinned to `k3s-node-02`; uses local NVMe for incomplete + stay-local categories | config: `qbt-br-config-lh` (Longhorn); local: `hostPath /mnt/nvme/local/qbt-br` → `/local` |
| **qbt-se**      | Pinned to `k3s-node-02`; uses local NVMe for incomplete + stay-local categories | config: `qbt-se-config-lh` (Longhorn); local: `hostPath /mnt/nvme/local/qbt-se` → `/local` |
| **qBittorrent** | Pinned to `k3s-node-01`; needs local SSD for incomplete downloads               | config: Longhorn; incomplete: `hostPath /mnt/ssd/local/qbt-incomplete`                     |
| **SABnzbd**     | Pinned to `k3s-node-01`; needs local SSD for incomplete downloads               | config: Longhorn; incomplete: `hostPath /mnt/ssd/local/sabnzbd-incomplete`                 |
| **Plex**        | Pinned to `k3s-server` for AMD GPU transcoding                                  | config: `plex-config-lh` (Longhorn); transcode: `hostPath /mnt/ssd/local/plex`             |
| **Emby**        | Pinned to `k3s-node-02` for Intel UHD 770 Quick Sync transcoding                | config: `emby-config-lh` (Longhorn); transcode: `hostPath /mnt/nvme/local/emby`            |

The `media-data` NFS PVC (UNAS-4) is untouched — Longhorn is only for app config volumes.

## Disk layout

Longhorn data lives on each node's NVMe (`/mnt/nvme/longhorn`). A second single-partition local hostPath holds node-specific workloads — the SATA SSD on `k3s-server`/`k3s-node-01`, a dedicated NVMe partition on `k3s-node-02` (no SATA disk).

| Node        | Disk | Mount                | Purpose                                                             |
| ----------- | ---- | -------------------- | ------------------------------------------------------------------- |
| k3s-server  | NVMe | `/mnt/nvme/longhorn` | Longhorn data path (~195 GiB)                                       |
| k3s-server  | SATA | `/mnt/ssd/local`     | Plex transcode hostPath (~931 GiB)                                  |
| k3s-node-01 | NVMe | `/mnt/nvme/longhorn` | Longhorn data path (~195 GiB)                                       |
| k3s-node-01 | SATA | `/mnt/ssd/local`     | SABnzbd incomplete downloads (~931 GiB)                             |
| k3s-node-02 | NVMe | `/mnt/nvme/longhorn` | Longhorn data path (~195 GiB)                                       |
| k3s-node-02 | NVMe | `/mnt/nvme/local`    | qBittorrent clients' incomplete/staging + Emby transcode (~1.6 TiB) |

See [Hardware](hardware.md) for the full NVMe partition table.

## Disk preparation

The NVMe partition layout is set during OS install (Ubuntu Server, manual partitioning). The SATA SSD is wiped and formatted as a single partition during the same install window.

After first boot on each node, create the app-owned hostPath directories:

### k3s-server

```bash
df -h /mnt/nvme/longhorn /mnt/ssd/local   # verify mounts came up

sudo mkdir -p /mnt/ssd/local/plex
sudo chown 1000:1000 /mnt/ssd/local/plex
```

### k3s-node-01

```bash
df -h /mnt/nvme/longhorn /mnt/ssd/local   # verify mounts came up

sudo mkdir -p /mnt/ssd/local/qbt-incomplete /mnt/ssd/local/sabnzbd-incomplete
sudo chown 1000:1000 /mnt/ssd/local/qbt-incomplete /mnt/ssd/local/sabnzbd-incomplete
```

### k3s-node-02

```bash
df -h /mnt/nvme/longhorn /mnt/nvme/local   # verify mounts came up

sudo mkdir -p /mnt/nvme/local/qbt-br /mnt/nvme/local/qbt-se /mnt/nvme/local/emby
sudo chown 1000:1000 /mnt/nvme/local/qbt-br /mnt/nvme/local/qbt-se /mnt/nvme/local/emby
```

`hostPathType: DirectoryOrCreate` auto-creates the dirs as `root:root`, which the qBt container (running as `1000:1000` via `PUID/PGID`) can't write to — the `chown` is mandatory.

# Longhorn installation and setup

## Prerequisites (Ansible)

```bash
ansible/k3s/install-k3s.yaml
```

This installs `open-iscsi` and enables `iscsid` on all nodes. These are required for Longhorn block storage and NFSv3 locking respectively.

## Helm install

```bash
ansible-playbook ansible/k3s/longhorn.yaml
```

This installs Longhorn via Helm (`longhorn/longhorn`, pinned version), patches the `default` BackupTarget CR with the NFS backup URL, and removes the `is-default-class` annotation from `local-path` so Longhorn becomes the sole default StorageClass.

## Verify

```bash
# All three nodes: READY=True, SCHEDULABLE=True
kubectl -n longhorn-system get nodes.longhorn.io

# All Running: longhorn-manager (one per node), longhorn-driver-deployer, csi-*, engine-image-*, longhorn-ui (x2)
kubectl -n longhorn-system get pods

# longhorn (default), local-path (no default annotation)
kubectl get sc
```

Open the Longhorn UI at `https://longhorn.hl.mathielo.com` to inspect disk registration and volume health.

# Backups

## Backup target

Longhorn backs up to the dedicated `k3s` NFS share on UNAS-4:

```
nfs://10.10.1.4:/var/nfs/shared/k3s?nfsOptions=vers=3,actimeo=1,soft,timeo=300,retry=2
```

This is configured in `ansible/k3s/files/longhorn.values.yaml` and patched onto the `default` BackupTarget CR by the Ansible playbook. Longhorn creates a `backupstore/` directory tree inside the share root.

> :bulb: The `nfsOptions` force NFSv3 (UNAS exports NFSv3) and preserve Longhorn's recommended mount options for backup reliability.

## Creating a backup

A daily backup job is defined as `RecurringJob` CRs declared in `k3s/apps/media/_infra/`, which is managed by ArgoCD.

**Via the UI** (`https://longhorn.hl.mathielo.com`):

1. Go to **Volumes** — find the volume (named after the PVC, e.g. `pvc-b49ada02-...`)
2. Click the volume → **Create Backup** → confirm
3. The backup appears under **Backup** in the left nav once complete

**Via recurring jobs** (recommended for automation):

In the Longhorn UI: **Recurring Jobs** → **Create** — set `type=backup`, `cron` schedule (e.g. `0 2 * * *` for 2 AM daily), `retain` count, and attach it to the volumes you want covered.

## Viewing backups

```bash
# List all backup volumes (one entry per source Longhorn volume that has backups)
kubectl -n longhorn-system get backupvolumes

# List individual backups for a specific volume
kubectl -n longhorn-system get backups -l longhornvolume=<pvc-volume-name>
```

Or in the UI: **Backup** → select a volume to see its backup history with timestamps and sizes.

## Restoring from backup

**Restore to a new PVC** (safest — keeps the broken volume untouched):

1. UI → **Backup** → find the backup volume → select a backup point → **Restore Latest Backup**
2. Give the restored volume a name (e.g. `radarr-config-restored`)
3. Once the volume is `Ready`, create a PVC that binds to it, or use the restored volume directly
4. Swap `existingClaim` in values.yaml to point at the restored PVC, commit, let ArgoCD sync

**Via kubectl:**

```bash
# Trigger restore from the latest backup of a given backup volume
kubectl -n longhorn-system create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: radarr-config-restored
  namespace: longhorn-system
spec:
  fromBackup: "nfs://10.10.1.4:/var/nfs/shared/k3s?nfsOptions=...&backup=<backup-url>"
  numberOfReplicas: 2
  size: "2147483648"
EOF
```

The backup URL is shown in `kubectl get backup -n longhorn-system <backup-name> -o yaml` under `.status.url`.

## Recovering an accidentally-deleted PVC

Because `reclaimPolicy: Delete`, deleting a PVC propagates: the PV and the Longhorn volume go with it. The recovery path uses the latest backup on UNAS-4 and pre-binds a freshly-restored volume back to the original PVC name (the one declared in `k3s/apps/media/_infra/longhorn-pvcs.yaml`), so ArgoCD's reconcile finishes the job.

The PVC manifest is still in git, so step zero is "don't panic — Argo will recreate the PVC; it'll just be empty until we point it at restored data."

1. **Pause Argo auto-sync for the affected app** (so it doesn't bind the empty PVC to a fresh, blank Longhorn volume before you can intervene). UI → app → App Details → disable auto-sync. Or:

   ```bash
   kubectl -n argocd patch application <app> --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
   ```

2. **Identify the backup.** UI → Backup → find the backup volume (named after the old PV, e.g. `pvc-b49ada02-...`). Note its size and the most recent backup point's URL (`kubectl -n longhorn-system get backup <name> -o jsonpath='{.status.url}'`).

3. **Restore the backup into a new Longhorn volume.** UI → Backup → select the backup → **Restore Latest Backup** → give it a distinctive name, e.g. `<pvc-name>-restored`, replicas `2`. Wait for the volume to become `Detached` (ready).

4. **Create a PV that wraps the restored volume and pre-binds to the original PVC name:**

   ```yaml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: <pvc-name>-restored # any name; not user-visible after binding
   spec:
     capacity:
       storage: <original-size> # e.g. 2Gi — match the PVC's request
     accessModes: [ReadWriteOnce]
     storageClassName: longhorn
     persistentVolumeReclaimPolicy: Delete
     csi:
       driver: driver.longhorn.io
       fsType: ext4
       volumeHandle: <pvc-name>-restored # MUST equal the Longhorn volume name from step 3
     claimRef:
       apiVersion: v1
       kind: PersistentVolumeClaim
       namespace: media
       name: <pvc-name> # original PVC name — what's in longhorn-pvcs.yaml
   ```

   Apply with `kubectl apply -f restored-pv.yaml`. The pre-set `claimRef` (without `uid`) reserves the PV for that namespaced name.

5. **Re-enable Argo auto-sync.** Argo recreates the PVC from `longhorn-pvcs.yaml`; the PVC controller sees the matching `claimRef` on the restored PV and binds. The pod starts and sees its data.

   ```bash
   kubectl -n argocd patch application <app> --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
   ```

6. **Verify** in the app's UI that history/library/config came back; check `kubectl -n media get pvc <pvc-name>` shows `Bound` to the restored PV.

If you skipped step 1 and Argo already created the PVC bound to a blank volume: delete that PVC + PV (the blank volume will be cleaned up via `Delete`), then proceed from step 2 — `claimRef` pre-binding only works if no PVC is currently in flight for that name.

# Operational notes

## Node loss and serial reboots

With 3 nodes, `replicaSoftAntiAffinity: false` (strict), and 2 replicas per volume, each volume's two replicas land on two of the three nodes. Losing a single node degrades only the volumes that had a replica there (roughly two-thirds of them) — and because a spare node is now available and strict anti-affinity is still satisfiable, Longhorn rebuilds the missing replica onto that spare automatically, without waiting for the downed node to return.

**Still reboot nodes serially**, one at a time, waiting for all volumes to return to `Healthy` between reboots. Rebooting two nodes at once can take down both replicas of any volume that happened to be placed on that pair, which means data unavailability until one returns.

```bash
# Check volume health before rebooting a node
kubectl -n longhorn-system get volumes | grep -v Healthy
# Should return nothing if all volumes are healthy
```

## Settings drift

`defaultSettings.defaultDataPath` in `longhorn.values.yaml` only takes effect on the **first install**. Subsequent Helm upgrades do not re-apply settings that Longhorn stores as CRs. To change a setting on a running cluster, edit it in the UI or patch the `Setting` CR:

```bash
kubectl -n longhorn-system patch setting default-data-path --type merge \
  -p '{"value":"/mnt/nvme/longhorn"}'
```

# Troubleshooting

## Replica scheduling failures

Longhorn cannot place a second replica if only one node is available. Check:

```bash
kubectl -n longhorn-system get replicas | grep -v Running
kubectl -n longhorn-system get nodes.longhorn.io
```

If a node shows `SCHEDULABLE=False`, check disk pressure or that Longhorn's disk path is mounted:

```bash
ssh <node> 'df -h /mnt/nvme/longhorn'
```

## Multipath conflicts (`mke2fs ... apparently in use`)

Symptom: a freshly-bound Longhorn PVC sticks in `ContainerCreating`, with kubelet events:

```
MountVolume.MountDevice failed ... format of disk "/dev/longhorn/pvc-..." failed
mke2fs ... /dev/longhorn/pvc-... is apparently in use by the system; will not make a filesystem here!
```

Cause: `multipathd` on the node has wrapped Longhorn's iSCSI LUN (`IET,VIRTUAL-DISK`) as an `mpath` device. The CSI driver's `mkfs.ext4` then fails because the kernel reports the underlying `sd*` busy. PVCs that were already formatted skip the mkfs path and keep working — only newly-created Longhorn volumes hit this.

```bash
ssh <node> 'sudo multipath -ll'
# Any mpath* entry showing IET,VIRTUAL-DISK confirms the issue.
```

For this reason multipath blacklist was added to Longhorn's Ansible playbook. It installs a vendor blacklist for `IET` LUNs at `/etc/multipath.conf` and reloads `multipathd`:

## iscsid health

```bash
ssh k3s-server  'systemctl is-active iscsid'
ssh k3s-node-01 'systemctl is-active iscsid'
ssh k3s-node-02 'systemctl is-active iscsid'
# If inactive: sudo systemctl start iscsid
# Persistent fix: ansible-playbook ansible/k3s/install-k3s.yaml
```

## Backup target errors

```bash
kubectl -n longhorn-system get backuptarget default -o yaml | grep -A5 conditions
```

Common causes:

- `rpc.statd is not running` — run `sudo systemctl start rpc-statd` on k3s nodes; permanent fix is in `install-k3s.yaml`
- `No such file or directory` — the NFS path must be the **export root** (e.g. `/var/nfs/shared/k3s`), not a subdirectory inside it
- `remote share not in 'host:dir' format` — ensure the URL has a colon before the path: `nfs://host:/path`

## Degraded volumes after pod restart

If a volume is `Degraded` with one replica `Stopped`, Longhorn rebuilds the missing replica automatically onto any available node (it no longer has to wait for the offline node to return, since a third node can host the rebuild). Force a rebuild:

```bash
kubectl -n longhorn-system get replicas -o wide
# Find the stopped replica, then:
kubectl -n longhorn-system delete replica <stopped-replica-name>
# Longhorn schedules a new replica automatically
```
