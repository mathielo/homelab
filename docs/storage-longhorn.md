# Longhorn Distributed Block Storage

## Why Longhorn

Longhorn stores each volume as two replicas across both k3s nodes, so pods can move freely between `k3s-server` and `k3s-node-01` without data loss or manual intervention.

This also enables for HA should services require more than one replica.

### What runs on Longhorn

All pods have their config + data set in Longhorn PVCs. A few services have some extra mounts for specific purposes:

- qBittorrent + SABnzbd: local SSD mount for ongoing downloads
- Plex: local SSD mount for active transcode

### What stays pinned (not on Longhorn)

| App             | Why pinned                                                        | Storage                                                                                  |
| --------------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| **qBittorrent** | Pinned to `k3s-node-01`; needs local SSD for incomplete downloads | config: Longhorn; incomplete: `hostPath /mnt/ssd/local/qbt-incomplete`                   |
| **SABnzbd**     | Pinned to `k3s-node-01`; needs local SSD for incomplete downloads | config: Longhorn; incomplete: `hostPath /mnt/ssd/local/sabnzbd-incomplete`               |
| **Plex**        | Pinned to `k3s-server` for AMD GPU transcoding                    | config: `plex-config-lh` (Longhorn); transcode: `hostPath /mnt/ssd/local/plex-transcode` |

The `media-data` NFS PVC (UNAS-4) is untouched — Longhorn is only for app config volumes.

## Disk layout

Each node has a 1 TB Kingston SATA SSD at `/dev/sda`, partitioned as:

| Node        | Partition   | Size    | Mount               | Purpose                                    |
| ----------- | ----------- | ------- | ------------------- | ------------------------------------------ |
| k3s-server  | `/dev/sda1` | 300 GB  | `/mnt/ssd/longhorn` | Longhorn data path                         |
| k3s-server  | `/dev/sda2` | ~654 GB | `/mnt/ssd/local`    | Plex transcode + future hostPaths          |
| k3s-node-01 | `/dev/sda1` | 100 GB  | `/mnt/ssd/longhorn` | Longhorn data path                         |
| k3s-node-01 | `/dev/sda2` | ~854 GB | `/mnt/ssd/local`    | qBittorrent + SABnzbd incomplete downloads |

## Disk preparation (manual, per node)

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
sudo mkdir -p /mnt/ssd/longhorn /mnt/ssd/local/qbt-incomplete /mnt/ssd/local/sabnzbd-incomplete
sudo chown 1000:1000 /mnt/ssd/local/qbt-incomplete /mnt/ssd/local/sabnzbd-incomplete
```

# Longhorn installation and setup

## Prerequisites (Ansible)

```bash
ansible/k3s/install-k3s.yaml
```

This installs `open-iscsi` and enables `iscsid` on both nodes. These are required for Longhorn block storage and NFSv3 locking respectively.

## Helm install

```bash
ansible-playbook ansible/k3s/longhorn.yaml
```

This installs Longhorn via Helm (`longhorn/longhorn`, pinned version), patches the `default` BackupTarget CR with the NFS backup URL, and removes the `is-default-class` annotation from `local-path` so Longhorn becomes the sole default StorageClass.

## Verify

```bash
# Both nodes: READY=True, SCHEDULABLE=True
kubectl -n longhorn-system get nodes.longhorn.io

# All Running: longhorn-manager (x2), longhorn-driver-deployer, csi-*, engine-image-*, longhorn-ui (x2)
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

# Operational notes

## 2-node fragility

With only 2 nodes and `replicaSoftAntiAffinity: false` (strict), every volume has exactly one replica per node. If one node goes offline, all volumes degrade — pods can still run on the surviving node but replicas won't rebuild until the missing node returns.

**Do not reboot both nodes simultaneously.** Reboot serially: reboot one, wait for all volumes to return to `Healthy`, then reboot the other.

```bash
# Check volume health before rebooting a node
kubectl -n longhorn-system get volumes | grep -v Healthy
# Should return nothing if all volumes are healthy
```

## Settings drift

`defaultSettings.defaultDataPath` in `longhorn.values.yaml` only takes effect on the **first install**. Subsequent Helm upgrades do not re-apply settings that Longhorn stores as CRs. To change a setting on a running cluster, edit it in the UI or patch the `Setting` CR:

```bash
kubectl -n longhorn-system patch setting default-data-path --type merge \
  -p '{"value":"/mnt/ssd/longhorn"}'
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
ssh <node> 'df -h /mnt/ssd/longhorn'
```

## iscsid health

```bash
ssh k3s-server  'systemctl is-active iscsid'
ssh k3s-node-01 'systemctl is-active iscsid'
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

If a volume is `Degraded` with one replica `Stopped`, the replica on the offline node will rebuild automatically once both nodes are up. Force a rebuild:

```bash
kubectl -n longhorn-system get replicas -o wide
# Find the stopped replica, then:
kubectl -n longhorn-system delete replica <stopped-replica-name>
# Longhorn schedules a new replica automatically
```
