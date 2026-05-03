# NVMe SSD upgrade — k3s-server + k3s-node-01 (512 GB)

## Context

Both k3s nodes today have a ~235 GB NVMe (Ubuntu rootfs + LVM, fully allocated `VFree=0`) plus a 1 TB SATA SSD partitioned as `/mnt/ssd/longhorn` + `/mnt/ssd/local`. Longhorn lives on the SATA SSD because there was no room left on the NVMe.

The plan is to replace both NVMes with **512 GB NVMe M.2** drives. Goals:

1. **Move Longhorn onto the NVMe** (faster fsync for SQLite-heavy ARR config DBs, cleaner failure isolation between OS and download cache).
2. **Reclaim the SATA SSD** entirely for downloads in progress + Plex transcode.
3. **Generous headroom** so this doesn't need to happen again soon.
4. **No data loss**, **minimal downtime** — only the node-pinned services (qBittorrent + SABnzbd on `k3s-node-01`; Plex on `k3s-server`) should go down, and only while their host node is being reinstalled.

The multipath blacklist for Longhorn iSCSI LUNs (`ansible/k3s/files/multipath-longhorn.conf`, applied via `ansible/k3s/longhorn.yaml`) is in place — newly-formatted Longhorn volumes on the new disks won't trip the `mke2fs ... apparently in use` failure mode.

## Hardware & partitioning

Per node, on the 512 GB NVMe:

| Mount               | Size   | FS    | Purpose                               |
| ------------------- | ------ | ----- | ------------------------------------- |
| EFI (`/boot/efi`)   | 1 GB   | vfat  | Ubuntu boot                           |
| `/boot`             | 2 GB   | ext4  | Kernel/initramfs                      |
| `/` (rootfs)        | 128 GB | ext4  | Ubuntu + k3s + container images       |
| `/mnt/nvme/longhorn` | ~380 GB | ext4 | Longhorn data path                    |

Notes:

- **Why 128 / ~380, not 50/50.** Rootfs needs ~10 GB OS + ~30 GB container images + headroom; 128 GB is luxurious. Putting the rest into Longhorn maximizes the upgrade's value. 50/50 (256/256) wastes ~120 GB on rootfs that will never get used.
- **LVM vs raw partitions.** Use plain partitions (no LVM). LVM was the cause of the current `VFree=0` predicament; flat partitions are simpler and we don't need volume management here.
- The **SATA SSD is untouched during the upgrade** — same physical drive, same data on `/mnt/ssd/local`. Repartitioning it (collapsing the unused `/mnt/ssd/longhorn` partition into a single bigger `/mnt/ssd/local`) is a separate, optional follow-up — not part of this plan.

## Pre-flight (do once, before any swap)

1. **Verify Longhorn backups are current.** UI → Backup → confirm a recent successful backup for every active volume. If a recurring backup hasn't run yet, trigger one per volume now.

   ```bash
   sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n longhorn-system get backups
   ```

2. **Save a k3s etcd snapshot and copy it off-cluster:**

   ```bash
   ssh k3s-server 'sudo k3s etcd-snapshot save --name pre-nvme-upgrade'
   ssh k3s-server 'ls /var/lib/k3s/server/db/snapshots/'
   # Pull a copy somewhere outside both nodes (UNAS or your laptop):
   rsync -av k3s-server:/var/lib/k3s/server/db/snapshots/pre-nvme-upgrade-* ~/Backups/
   ```

3. **Sanity-check IaC ground truth.** Confirm `ansible/inventory.ini` matches the IPs UniFi has reserved (`10.10.50.10`, `10.10.50.11`), and that your SSH key is in `~/.ssh/authorized_keys` for the install user (`m8hl`).

## Phase 1 — replace `k3s-node-01` NVMe (agent)

Outage scope: **qBittorrent + SABnzbd** (pinned to this node). Everything else stays up on `k3s-server`.

1. **Drain the agent.** In the Longhorn UI, set `k3s-node-01` → Disable scheduling and Disable eviction-requested (we're going to wipe the disk anyway, so don't waste cycles evacuating). Then:

   ```bash
   sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl cordon k3s-node-01
   sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl drain k3s-node-01 \
     --ignore-daemonsets --delete-emptydir-data
   ```

   With `replicaSoftAntiAffinity: false`, replicas on the surviving server will stay single-replica (`Degraded`) until the agent comes back. Expected.

2. **Remove the node from Longhorn and Kubernetes:**

   ```bash
   sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl delete node k3s-node-01
   ```

   Longhorn-manager will mark the agent's replicas as `failed` after the stale replica timeout — that's fine, they'll be rebuilt fresh on the new disk.

3. **Power off, swap NVMe physically.** Leave the SATA SSD in place.

4. **Install Ubuntu Server 24.04 LTS** (match `k3s-server`'s version). Manual partitioning per the table above. Hostname `k3s-node-01`, static IP `10.10.50.11` via UniFi reservation, ensure SSH for `m8hl` works with the existing key.

5. **Mount the SATA `/mnt/ssd/local`** from the surviving partition into fstab (UUID lookup with `blkid`). The old `/mnt/ssd/longhorn` partition stays unmounted — it'll be reclaimed in the optional follow-up.

6. **Re-run the cluster Ansible:**

   ```bash
   ansible-playbook ansible/k3s/install-k3s.yaml
   ansible-playbook ansible/k3s/longhorn.yaml   # multipath blacklist + Helm reconcile
   ```

7. **Switch Longhorn's data path.** Edit `ansible/k3s/files/longhorn.values.yaml`:
   ```diff
   -  defaultDataPath: /mnt/ssd/longhorn
   +  defaultDataPath: /mnt/nvme/longhorn
   ```
   Update `docs/storage-longhorn.md` and `docs/hardware.md` partition tables. Re-run `ansible-playbook ansible/k3s/longhorn.yaml` so the default takes effect for new node registrations.

   > `defaultDataPath` only applies on **first registration of a node**. Existing nodes (k3s-server until phase 2) keep their current disk record. We add/remove disks per node manually in the next step.

8. **Add the new disk in the Longhorn UI.** Settings → Node → `k3s-node-01` → add disk path `/mnt/nvme/longhorn`. Then disable + remove the old `/mnt/ssd/longhorn` record on this node (it no longer exists).

9. **Re-enable scheduling on `k3s-node-01`** (Longhorn UI). Uncordon:

   ```bash
   sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl uncordon k3s-node-01
   ```

10. **Wait for replicas to rebuild** — Longhorn UI → Volumes, all should return to `Healthy` with two replicas. qBt and SAB pods come back automatically via their node selector.

## Phase 2 — replace `k3s-server` NVMe (control plane)

Outage scope: **Plex** (pinned). Pods on `k3s-node-01` keep running while the server is offline (k3s agents keep existing workloads alive without a reachable server), but no scheduling decisions can happen during this window.

1. **Re-take a fresh etcd snapshot** (just before powering down):

   ```bash
   ssh k3s-server 'sudo k3s etcd-snapshot save --name pre-server-swap'
   rsync -av k3s-server:/var/lib/k3s/server/db/snapshots/pre-server-swap-* ~/Backups/
   ```

2. **Drain & remove the server from the cluster.** Since this is a single-server k3s, you can't gracefully `kubectl delete node k3s-server` while it's the API server itself. Just power off after taking the snapshot — the node disappears from the API once it's gone.

3. **Power off, swap NVMe.** Same partition layout as phase 1.

4. **Install Ubuntu Server 24.04 LTS.** Hostname `k3s-server`, static IP `10.10.50.10`, partitioning per the table above. `/mnt/ssd/local` (Plex transcode) re-mounted from existing SATA SSD by UUID.

5. **Reinstall k3s-server, then restore from snapshot:**

   ```bash
   # Copy the snapshot back into place first
   rsync -av ~/Backups/pre-server-swap-* k3s-server:/tmp/

   # Reinstall k3s with the install playbook
   ansible-playbook ansible/k3s/install-k3s.yaml

   # Stop k3s, restore from snapshot, restart
   ssh k3s-server '
     sudo systemctl stop k3s
     sudo k3s server --cluster-reset --cluster-reset-restore-path=/tmp/pre-server-swap-<timestamp>
     sudo systemctl start k3s
   '
   ```

   The reset bootstraps a new etcd from the snapshot. All CRDs, deployments, PVCs, PVs come back. Argo / cert-manager / ingress / Longhorn manifests reconcile automatically.

6. **Re-run Longhorn playbook** for the multipath blacklist and Helm reconcile:

   ```bash
   ansible-playbook ansible/k3s/longhorn.yaml
   ```

7. **In the Longhorn UI:** add the new disk path `/mnt/nvme/longhorn` on `k3s-server`; disable + remove the old `/mnt/ssd/longhorn` disk record. Replicas rebuild from the surviving copies on `k3s-node-01`.

8. **Wait for all volumes `Healthy` (2 replicas).** Plex comes back automatically once `k3s-server` is uncordoned and replicas exist.

## Critical files

| File | Change |
|------|--------|
| `ansible/k3s/files/longhorn.values.yaml` | `defaultDataPath: /mnt/ssd/longhorn` → `/mnt/nvme/longhorn` |
| `docs/storage-longhorn.md` | Update partition tables and disk-prep section to NVMe layout |
| `docs/hardware.md` | Update SSD inventory + partition tables (NVMe is now Longhorn's home) |
| `ansible/inventory.ini` | No change expected (IPs preserved via UniFi DHCP reservation) |

The multipath conf is already in place — it rides along but requires no per-phase changes.

## Verification

After each phase:

```bash
# Both nodes Ready and Schedulable
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n longhorn-system get nodes.longhorn.io

# All Longhorn volumes Healthy with 2 replicas
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n longhorn-system get volumes \
  | awk '$2!="attached" || $3!="healthy"'    # should print only the header

# New data path visible
ssh <node> 'df -h /mnt/nvme/longhorn'
ssh <node> 'sudo multipath -ll'              # no IET,VIRTUAL-DISK lines

# All pods Running, Argo apps Synced/Healthy
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get pods -A | grep -vE 'Running|Completed'
```

End-to-end: open the qBt, SAB, ARR, and Plex web UIs and confirm history/library is intact.

## Rollback

- **Phase 1 only swapped:** put the old NVMe back into `k3s-node-01`, boot, the cluster picks up where it was. Longhorn replicas on the agent are still there.
- **Phase 2 swap fails or snapshot restore corrupt:** put the old NVMe back into `k3s-server`. If that disk has also been wiped, redeploy k3s + apps fresh from Ansible/Argo and restore Longhorn volumes from UNAS-4 backups (`fromBackup:` on a new Volume CR — example in `docs/storage-longhorn.md`). Longest path, but every config volume has a backup.

## Optional follow-up (not part of this upgrade)

- Repartition the SATA SSD on each node into a single big `/mnt/ssd/local` (collapsing the now-unused `/mnt/ssd/longhorn` partition). Reclaims ~300 GB on `k3s-server` and ~100 GB on `k3s-node-01` for downloads/transcode. Can be done online with `parted` / `resize2fs`, no data loss on `/mnt/ssd/local` if `/mnt/ssd/longhorn` is the partition being absorbed.
