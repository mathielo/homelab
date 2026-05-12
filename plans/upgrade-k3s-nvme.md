# k3s NVMe repartition — k3s-node-01 + k3s-server

## Context

Both k3s nodes today have a ~256 GB NVMe (Ubuntu rootfs + LVM, fully allocated `VFree=0`) plus a 1 TB Kingston SATA SSD partitioned as `/mnt/ssd/longhorn` + `/mnt/ssd/local`. Longhorn lives on the SATA SSD because the original LVM layout left no room on the NVMe.

The plan is to **keep the existing 256 GB NVMes** but reinstall **Ubuntu Server 26.04 LTS** with a clean partition layout that fits Longhorn on the NVMe. Goals:

1. **Move Longhorn onto the NVMe** (faster fsync for SQLite-heavy ARR config DBs, cleaner failure isolation between OS and download cache).
2. **Reclaim the SATA SSD entirely** for its node-specific role:
   - `k3s-node-01` SATA → qBittorrent + SABnzbd incomplete downloads only.
   - `k3s-server` SATA → Plex transcode only.
3. **No data loss for Longhorn-backed data**, **minimal downtime** — only the node-pinned services (qBittorrent + SABnzbd on `k3s-node-01`; Plex on `k3s-server`) should go down, and only while their host node is being reinstalled.

The multipath blacklist for Longhorn iSCSI LUNs (`ansible/k3s/files/multipath-longhorn.conf`, applied via `ansible/k3s/longhorn.yaml`) is in place — newly-formatted Longhorn volumes on the new disks won't trip the `mke2fs ... apparently in use` failure mode.

## Hardware & partitioning

Per node, on the existing 256 GB NVMe (~238 GiB usable):

| Mount                | Size      | FS    | Purpose                                       |
| -------------------- | --------- | ----- | --------------------------------------------- |
| `/boot/efi`          | 1 GiB     | vfat  | Ubuntu boot                                   |
| `/boot`              | 2 GiB     | ext4  | Kernel/initramfs                              |
| `/` (rootfs)         | 40 GiB    | ext4  | Ubuntu + k3s + container image cache          |
| `/mnt/nvme/longhorn` | ~195 GiB  | ext4  | Longhorn distributed block data               |

Notes:

- **Why 40 GiB root.** Ubuntu Server 26.04 base install is ~5-6 GiB; k3s + containerd image cache typically ~15-20 GiB; journald/snap/logs ~3 GiB. Leaves ~10-15 GiB headroom — adequate for a stateless k3s node where all data lives elsewhere. If `/var/lib/k3s` ever pressures `/`, GC image cache: `sudo k3s crictl rmi --prune`.
- **Longhorn gets the rest.** ~195 GiB is comfortably larger than current usage (tens of GB across all PVCs) and matches what we'd otherwise reserve. Headroom for new apps.
- **LVM vs raw partitions.** Use plain partitions (no LVM). LVM was the cause of the current `VFree=0` predicament; flat partitions are simpler and we don't need volume management here.

Per node, the **1 TB SATA SSD** (`/dev/sda`) is wiped and repartitioned as a single full-disk partition during the OS install window:

| Node        | Partition   | Size     | FS   | Mount            | Purpose                                    |
| ----------- | ----------- | -------- | ---- | ---------------- | ------------------------------------------ |
| k3s-node-01 | `/dev/sda1` | ~931 GiB | ext4 | `/mnt/ssd/local` | qBittorrent + SABnzbd incomplete downloads |
| k3s-server  | `/dev/sda1` | ~931 GiB | ext4 | `/mnt/ssd/local` | Plex transcode                             |

> :warning: Wiping the SATA SSD destroys in-flight qBt/SAB downloads (Phase 1) and Plex transcode cache (Phase 2). Both are acceptable: torrents resume, usenet jobs restart, transcode regenerates. Sanity-check `/mnt/ssd/local` for anything unexpected before each phase.

## Pre-flight (do once, before any reinstall)

1. **Confirm Longhorn replicas are healthy on both nodes** (so wiping a node leaves a valid surviving replica for every volume):

   ```bash
   sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n longhorn-system get volumes \
     | awk '$2!="attached" || $3!="healthy"'   # should print only the header
   sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n longhorn-system get replicas -o wide
   ```

2. **Trigger a fresh backup for every Longhorn volume.** UI → Volumes → select all → Create Backup. Verify:

   ```bash
   sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n longhorn-system get backups
   ```

3. **Save a k3s etcd snapshot and copy it off-cluster:**

   ```bash
   ssh k3s-server 'sudo k3s etcd-snapshot save --name pre-nvme-repartition'
   ssh k3s-server 'ls /var/lib/k3s/server/db/snapshots/'
   rsync -av k3s-server:/var/lib/k3s/server/db/snapshots/pre-nvme-repartition-* ~/Backups/
   ```

4. **Record current SATA state** for reference (UUIDs will change after the wipe — this is just a sanity snapshot):

   ```bash
   ssh k3s-node-01 'lsblk -o NAME,SIZE,UUID,LABEL,MOUNTPOINT /dev/sda'
   ssh k3s-server  'lsblk -o NAME,SIZE,UUID,LABEL,MOUNTPOINT /dev/sda'
   ```

5. **Sanity-check IaC ground truth.** Confirm `ansible/inventory.ini` matches the IPs UniFi has reserved (`10.10.50.10`, `10.10.50.11`). Reservations are by MAC, so the same machine returning post-reinstall keeps its IP. SSH key for `m8hl` is set during the OS install step.

6. **Note pinned workloads** so you know what's expected down per phase:
   - Phase 1 (node-01): `qbittorrent`, `sabnzbd` (selector `workload=media`).
   - Phase 2 (server): `plex` (pinned to the server for AMD GPU transcoding).

7. **Have the Ubuntu Server 26.04 LTS ISO on a USB stick.** Verify the SHA256 checksum.

## Phase 1 — reinstall `k3s-node-01` (agent)

Outage scope: **qBittorrent + SABnzbd** (pinned to this node). Everything else stays up on `k3s-server`.

### 1.1 Drain the agent

In the Longhorn UI: Node → `k3s-node-01` → Edit Node → set **Node Scheduling: Disable** and leave **Eviction Requested: false** (we're wiping the disk anyway — don't waste cycles evacuating). Then:

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl cordon k3s-node-01
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl drain k3s-node-01 \
  --ignore-daemonsets --delete-emptydir-data --force
```

With `replicaSoftAntiAffinity: false`, replicas on the surviving server will stay single-replica (`Degraded`) until the agent comes back. Expected.

### 1.2 Remove the node from k3s

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl delete node k3s-node-01
```

Longhorn-manager will mark the agent's replicas as `failed` after the stale replica timeout — fine, they'll be rebuilt fresh on the new disk.

### 1.3 Boot the installer

Power off, plug in the Ubuntu Server 26.04 LTS USB stick, boot from it.

### 1.4 Install Ubuntu Server 26.04 LTS

In the disk step:

- **Manual partitioning** on `/dev/nvme0n1` (per the NVMe table above):
  - 1 GiB vfat → `/boot/efi`
  - 2 GiB ext4 → `/boot`
  - 40 GiB ext4 → `/`
  - remainder ext4 → `/mnt/nvme/longhorn`
- **`/dev/sda` (SATA SSD)** — also wipe + repartition fresh:
  - Single full-disk partition, ext4, mount `/mnt/ssd/local`
- **No LVM.** Flat partitions only.

Hostname `k3s-node-01`, user `m8hl`, paste SSH pubkey, IP `10.10.50.11` (UniFi DHCP reservation). Only `openssh-server` installed.

### 1.5 First-boot host config

```bash
# Confirm partitions/mounts came up
df -h /mnt/nvme/longhorn /mnt/ssd/local
lsblk

# Create app-owned hostPath dirs for qBt/SAB
sudo mkdir -p /mnt/ssd/local/qbt-incomplete /mnt/ssd/local/sabnzbd-incomplete
sudo chown -R 1000:1000 /mnt/ssd/local/qbt-incomplete /mnt/ssd/local/sabnzbd-incomplete
```

### 1.6 Update IaC for the new Longhorn path

Edit `ansible/k3s/files/longhorn.values.yaml`:

```diff
-  defaultDataPath: /mnt/ssd/longhorn
+  defaultDataPath: /mnt/nvme/longhorn
```

Update `docs/storage-longhorn.md` and `docs/hardware.md` partition tables to reflect the new NVMe + SATA layout.

> `defaultDataPath` only takes effect on a node's **first registration** with Longhorn. Because we deleted node-01 from k3s in step 1.2, its re-join counts as a first registration, so the new path is picked up automatically.

### 1.7 Rejoin the cluster

```bash
ansible-playbook ansible/k3s/install-k3s.yaml      # k3s agent install, iscsid, sysctls, NFS client
ansible-playbook ansible/k3s/longhorn.yaml         # multipath blacklist, helm reconcile
```

### 1.8 Verify Longhorn picked up the new disk

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n longhorn-system \
  get nodes.longhorn.io k3s-node-01 -o yaml | yq '.spec.disks'
```

Should show a disk entry for `/mnt/nvme/longhorn`. If it doesn't, or if the stale `/mnt/ssd/longhorn` record lingers, fix it in the UI: Node → `k3s-node-01` → Edit node and disks → add `/mnt/nvme/longhorn` (Schedulable=true) → remove the stale `/mnt/ssd/longhorn` entry.

### 1.9 Uncordon + re-enable scheduling

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl uncordon k3s-node-01
```

Longhorn UI: Node → `k3s-node-01` → Node Scheduling: Enable (if it didn't come up enabled).

### 1.10 Wait for replicas to rebuild

UI → Volumes — all return to `Healthy` with 2 replicas. qBt + SAB pods come back automatically via their node selector. Verify their incomplete dirs are intact (they were just re-created) and that the apps re-attach to their Longhorn config PVCs without errors.

## Phase 2 — reinstall `k3s-server` (control plane)

Outage scope: **Plex** (pinned). Pods on `k3s-node-01` keep running while the server is offline (k3s agents keep existing workloads alive without a reachable server), but no scheduling decisions can happen during this window.

### 2.1 Re-take a fresh etcd snapshot

```bash
ssh k3s-server 'sudo k3s etcd-snapshot save --name pre-server-reinstall'
rsync -av k3s-server:/var/lib/k3s/server/db/snapshots/pre-server-reinstall-* ~/Backups/
```

### 2.2 Drain the server

Longhorn UI: Node → `k3s-server` → Node Scheduling: Disable.

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl cordon k3s-server
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl drain k3s-server \
  --ignore-daemonsets --delete-emptydir-data --force
```

Plex is pinned to the server and will not reschedule. Other infra pods (Argo, cert-manager, ingress-nginx, MetalLB speakers) migrate to node-01 where possible; longhorn-manager runs as a DaemonSet on both.

> Since this is a single-server k3s, you can't gracefully `kubectl delete node k3s-server` while it's still the API server. Just power off after draining — the node disappears from the API once it's gone, and we restore the API from the etcd snapshot after reinstall.

### 2.3 Boot the installer

Power off, plug in the Ubuntu Server 26.04 LTS USB stick, boot from it.

### 2.4 Install Ubuntu Server 26.04 LTS

Same partitioning as Phase 1 (NVMe + SATA wipe). Hostname `k3s-server`, IP `10.10.50.10`.

### 2.5 First-boot host config

```bash
df -h /mnt/nvme/longhorn /mnt/ssd/local
lsblk

# Plex transcode hostPath
sudo mkdir -p /mnt/ssd/local/plex-transcode
sudo chown -R 1000:1000 /mnt/ssd/local/plex-transcode
```

### 2.6 Reinstall k3s server, then restore from snapshot

```bash
# Copy the snapshot back into place first
rsync -av ~/Backups/pre-server-reinstall-* k3s-server:/tmp/

# Reinstall k3s with the install playbook
ansible-playbook ansible/k3s/install-k3s.yaml

# Stop k3s, restore from snapshot, restart
ssh k3s-server '
  sudo systemctl stop k3s
  sudo k3s server --cluster-reset --cluster-reset-restore-path=/tmp/pre-server-reinstall-<timestamp>
  sudo systemctl start k3s
'
```

The reset bootstraps a new etcd from the snapshot. All CRDs, Deployments, PVCs, PVs come back. Argo / cert-manager / ingress / Longhorn manifests reconcile automatically.

### 2.7 Re-run the Longhorn playbook

```bash
ansible-playbook ansible/k3s/longhorn.yaml
```

### 2.8 Verify Longhorn picked up the new disk on the server

Same as 1.8 but for `k3s-server`. In the UI: add `/mnt/nvme/longhorn`, remove the stale `/mnt/ssd/longhorn` record. Replicas on the server rebuild from the surviving copies on `k3s-node-01`.

### 2.9 Uncordon

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl uncordon k3s-server
```

### 2.10 Wait for all volumes `Healthy` (2 replicas)

Plex comes back automatically once the server is uncordoned, replicas exist on local Longhorn disk, and `/mnt/ssd/local/plex-transcode` is in place.

## Critical files

| File                                       | Change                                                                       |
| ------------------------------------------ | ---------------------------------------------------------------------------- |
| `ansible/k3s/files/longhorn.values.yaml`   | `defaultDataPath: /mnt/ssd/longhorn` → `/mnt/nvme/longhorn`                  |
| `docs/storage-longhorn.md`                 | Update partition tables, disk-prep section, mount points (NVMe-based layout) |
| `docs/hardware.md`                         | Partition tables; SATA role per node (downloads on node-01, transcode on server) |
| `ansible/inventory.ini`                    | No change (IPs preserved via UniFi MAC reservations)                         |

The multipath conf is already in place — it rides along but requires no per-phase changes.

## Verification (after each phase)

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n longhorn-system get nodes.longhorn.io

# All Longhorn volumes Healthy with 2 replicas
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n longhorn-system get volumes \
  | awk '$2!="attached" || $3!="healthy"'    # should print only the header

# New data paths visible
ssh <node> 'df -h /mnt/nvme/longhorn /mnt/ssd/local'
ssh <node> 'sudo multipath -ll'              # no IET,VIRTUAL-DISK lines

# All pods Running, Argo apps Synced/Healthy
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get pods -A | grep -vE 'Running|Completed'
```

End-to-end: open the qBt, SAB, ARR, and Plex web UIs and confirm history/library/config intact.

## Rollback

Because we're reinstalling the existing NVMe (no hardware swap to revert to), rollback is destructive — you cannot simply "put the old disk back". The safety nets are the Longhorn backups on UNAS-4 and the etcd snapshot pulled in pre-flight.

- **Phase 1 fails before rejoin:** node-01's Longhorn data on the old NVMe/SATA is gone, but every volume still has a healthy replica on `k3s-server`. Worst case, leave node-01 out of the cluster, run on the server alone until you can retry. Volumes go `Degraded` (single replica) but stay attached.
- **Phase 2 swap fails or snapshot restore corrupt:** redeploy k3s + apps fresh from Ansible/Argo and restore Longhorn volumes from UNAS-4 backups (`fromBackup:` on a new Volume CR — example in `docs/storage-longhorn.md`). Longest path, but every config volume has a backup.
