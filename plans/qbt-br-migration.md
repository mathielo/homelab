# Migration: `qbittorrent` → `qbt-br` (multi-instance pivot)

This runbook turns the existing single `qbittorrent` deployment (Sweden VPN exit) into the first of a multi-region setup. The new instance is `qbt-br` (Brazil VPN exit). A future `qbt-se` will be added the same way later.

The approach is **destroy-and-rebuild**, not rename. Both instances run side-by-side briefly during migration (on different nodes — see node pinning below), then the old one is removed. Torrent state moves across via the qBittorrent WebUI API (export from old, import into new), so trackers see a clean re-add rather than a rename.

## Node pinning

The legacy `qbittorrent` runs on `k3s-node-01` with its incomplete dir on the SATA SSD at `/mnt/ssd/local/qbt`. The new `qbt-br` (and the future `qbt-se`) pin to `k3s-node-02`, which has the 2 TB Samsung 990 Pro NVMe and a partition at `/mnt/nvme/local` (~1.6 TiB) reserved for qBittorrent incomplete/staging. The Samsung 990 Pro has DRAM and is not SLC-cache constrained the way the Kingston SATA SSDs on the other nodes are, so the per-instance disk tuning (preallocate off, capped concurrent downloads, dl_limit ceiling) can be relaxed later if needed — but the values shipped here are conservative and fine to keep on node-02.

## What this PR ships

- New chart `k3s/apps/media/qbt-br/` (chart name `qbt-br`, release `qbt-br`, ingress `qbt-br.hl.mathielo.com`). Pinned to `k3s-node-02` via `nodeSelector`; `incomplete` hostPath is `/mnt/nvme/local/qbt-br-incomplete`. Chart depends on `app-template: "5.*"` (matches the current `qbittorrent` chart on `main`).
- New ArgoCD app `k3s/argocd/apps/qbt-br.yaml`.
- New Longhorn PVC `qbt-br-config-lh` in `k3s/apps/media/_infra/longhorn-pvcs.yaml`. The legacy `qbittorrent-config-lh` is left alone so the old instance keeps running until you cut over.
- Declarative-preferences pipeline: `values-prefs.yaml` + `templates/configmap-prefs.yaml` + qbittorrent-container `postStart` hook + `scripts/qbt/apply-prefs.sh` for hot reload.
- Migration scripts: `scripts/qbt/export-state.sh`, `scripts/qbt/import-state.sh`.
- `scripts/qbt/backup.sh` replaces the old top-level `scripts/qbt-backup.sh` and takes the instance label as `$1`.

The PR does **not** delete `k3s/apps/media/qbittorrent/`, `k3s/argocd/apps/qbittorrent.yaml`, or `qbittorrent-config-lh`. That happens in a small follow-up commit after the cutover succeeds.

## Prerequisites

- A second WireGuard private key for ProtonVPN that exits via Brazil. Generate it from the ProtonVPN dashboard (separate config from the SE one — don't reuse). Note `WIREGUARD_PRIVATE_KEY` and `WIREGUARD_ADDRESSES`.
- `kubectl`, `sops`, `helm`, `python3`, `curl` available locally.

## Step 1 — Rotate the BR WireGuard credentials

The copied `values.sops.yaml` still holds the SE creds. Replace them:

```sh
sops edit k3s/apps/media/qbt-br/values.sops.yaml
# Replace WIREGUARD_PRIVATE_KEY and WIREGUARD_ADDRESSES with the BR ones.
```

Do this **before** ArgoCD syncs the new app, otherwise gluetun will start a second WG session with the SE key and ProtonVPN may drop both.

## Step 2 — Export state from the running `qbittorrent`

While the old instance is still up:

```sh
scripts/qbt/export-state.sh qbittorrent ./qbt/export
```

This produces:

```
qbt/export/
├── preferences.json     ← reference dump (not re-applied)
├── categories.json      ← name → savePath map
├── tags.json            ← list of tag names
├── torrents.json        ← per-torrent: hash, category, tags, save_path
└── torrents/<hash>.torrent  ← .torrent file per active torrent
```

Stash this somewhere outside the repo — it contains tracker info you don't want committed.

## Step 3 — Optional: archive the legacy config PVC

Belt-and-suspenders backup of the old `/config` (qBittorrent.conf, RSS feeds, BT_backup .fastresume files) in case you want to inspect anything later:

```sh
scripts/qbt/backup.sh qbittorrent
```

## Step 4 — Merge and sync

Push the PR, merge, let ArgoCD reconcile. New objects appear:

- PVC `qbt-br-config-lh` (Longhorn, 1 Gi, empty)
- Application `qbt-br`, Pod `qbt-br-*`, Service `qbt-br`, Ingress `qbt-br`
- ConfigMap `qbt-br-prefs`
- TLS secret `qbt-br-hl-tls` (cert-manager issues against Cloudflare DNS-01)

The old `qbittorrent` deployment keeps running on `k3s-node-01`; the new `qbt-br` lands on `k3s-node-02`. Different nodes, different disks, different VPN sessions — no contention between them. The only shared resource is the NFS `media-data` PVC for completed-library hardlinks, which is read/write on both and fine.

Watch the rollout:

```sh
kubectl -n media get pod -l app.kubernetes.io/name=qbt-br -w
kubectl -n media logs -l app.kubernetes.io/name=qbt-br -c gluetun -f
```

Gluetun must reach "Connected. Wireguard is up" against a Brazilian server before qBittorrent will start. If it's looping, it's almost always the WG creds — re-check Step 1.

## Step 5 — Set the WebUI password on the new instance

The first qBittorrent boot generates a random WebUI password and prints it to the container log:

```sh
kubectl -n media logs -l app.kubernetes.io/name=qbt-br -c qbittorrent | grep -i "temporary password"
```

Log into `https://qbt-br.hl.mathielo.com` with `admin` + that temporary password, then **Tools → Options → Web UI → Authentication** and set:

- A real password
- "Bypass authentication for clients on localhost" → **enabled** (the postStart hook and Gluetun's port-forward up command rely on this)
- "Bypass authentication for clients in whitelisted IP subnets" → **enabled**, subnet `10.42.0.0/16` (in-cluster ARRs)

Verify the postStart hook applied prefs:

```sh
kubectl -n media exec deploy/qbt-br -c qbittorrent -- \
    wget -qO- http://localhost:8080/api/v2/app/preferences | python3 -m json.tool | grep -E "async_io|preallocate|disk_cache|max_active_downloads|dl_limit"
```

You should see `async_io_threads: 2`, `preallocate_all: false`, `disk_cache: -1`, `max_active_downloads: 2`, `dl_limit: 62914560`.

> The `dl_limit` value above is a starting ceiling, not a tuned one. See **Performance findings (NAS write bottleneck)** below — on node-02 it should be tied to measured NAS sustained write, and budgeted across instances once `qbt-se` is added.

## Step 6 — Import state into `qbt-br`

```sh
scripts/qbt/import-state.sh qbt-br ./qbt/export
```

Categories and tags re-create immediately. Torrents are added **paused** with `skip_checking=false`, so qBittorrent rechecks each one against the data already on the shared NFS `media-data` PVC. Completed torrents will resume seeding once the recheck finishes.

In the WebUI, sort by status, confirm everything is "Stopped" or "Checking", then **Tools → Resume All**.

## Step 7 — Repoint downstream services

These still reference `qbittorrent.media.svc.cluster.local` and need updating:

- **Sonarr** → Settings → Download Clients → qBittorrent: host `qbt-br.media.svc.cluster.local`, password from Step 5.
- **Radarr** → same.
- **Prowlarr** → if you proxy searches there, update the qBittorrent app entry too.
- **qui** (https://qui.hl.mathielo.com) → add `qbt-br` as a managed instance.

ARR clients track downloads by hash, and the imported torrents have the same hashes as before, so existing in-flight downloads should re-associate cleanly.

## Step 8 — Tear down the old `qbittorrent`

Once qbt-br has been steady for a few hours and you've confirmed seeding/imports work end-to-end, remove the old instance with a small follow-up commit:

```sh
git rm k3s/argocd/apps/qbittorrent.yaml
git rm -r k3s/apps/media/qbittorrent/
# Edit k3s/apps/media/_infra/longhorn-pvcs.yaml: delete the
# qbittorrent-config-lh PVC block.
```

Removing the ArgoCD app file triggers cascade deletion via the resource finalizer — Pod, Service, Ingress, TLS secret all go. The PVC removal in `longhorn-pvcs.yaml` deletes the volume and its data; only do this once you're sure the export was complete.

The hostPath `/mnt/ssd/local/qbt` on `k3s-node-01` doesn't auto-clean — `ssh k3s-node-01 sudo rm -rf /mnt/ssd/local/qbt` once you've confirmed nothing in there is needed.

## Rollback

If qbt-br misbehaves before Step 8, the old `qbittorrent` is still running and untouched — just stop using qbt-br, repoint ARRs back, and investigate. The ArgoCD app for qbt-br can be paused (`kubectl patch app/qbt-br -n argocd -p '{"spec":{"syncPolicy":null}}' --type=merge`) without disturbing the old one.

## Resource considerations

- The legacy `qbittorrent` (k3s-node-01, Ryzen 3 2200GE, SATA SSD) and the new `qbt-br` (k3s-node-02, i5-14500T, NVMe) live on separate hardware during the side-by-side window — no shared CPU, memory, or disk. Two concurrent ProtonVPN WireGuard sessions on the same account is the only thing to watch for; if Proton drops one, it's almost always the second-newest session.
- When you later add `qbt-se`, pin it to `k3s-node-02` as well (i5-14500T is the strongest CPU in the cluster and the only node with the right disk for qbt staging). Both `qbt-br` and `qbt-se` will share `k3s-node-02`'s NVMe at `/mnt/nvme/local` — give each its own subdir (`/mnt/nvme/local/qbt-br-incomplete`, `/mnt/nvme/local/qbt-se-incomplete`). The Samsung 990 Pro has DRAM and handles parallel writes well, so two instances on it is fine; just keep an eye on the `/mnt/nvme/local` partition's free space (~1.6 TiB total).

## Performance findings (NAS write bottleneck) — investigated 2026-05-15

Diagnosed while the legacy `qbittorrent` was on `k3s-node-01` with active torrents + a backlog of completed torrents moving to the NAS. The whole node showed load ~10 with every co-located pod slow. Findings that affect how `qbt-br` (and later `qbt-se`) should be configured on node-02:

- **Move serialization is already solved upstream — do not build an external mover.** qBittorrent moves torrent storages **one at a time** via an internal queue since v4.2.2 (PR [qbittorrent/qBittorrent#12035](https://github.com/qbittorrent/qBittorrent/issues/9407), closes #9407). We run 5.2.0, so this is active. Torrents waiting in the move queue still report `state=moving` over the API/WebUI — there is no distinct "queued-to-move" state, so e.g. "6 moving" = 1 actively copying + 5 queued, not 6 parallel copies. Caveat: a *manual* multi-select **Set location** can still bypass the queue (regression #22323, 5.0.3+); the automatic completion-move path qbt-br uses is unaffected.

- **The hard ceiling is the UNAS-4 write path, and node-02 does not raise it.** UNAS-4 is 4×24 TB 7200 RPM **RAID5** fronted by a read-write SSD cache that is ~90 % full on **consumer QLC** (Intel 660p) in RAID1 (observed write-hit ~15 %, read-hit ~33 %). Sustained completion-move throughput ≈ **30 MB/s** with multi-second latency. node-02's 990 Pro fixes the *incomplete/staging* disk and removes the writeback blast radius from node-01, **but the completion copy still lands on the same NAS share** — treat ~30 MB/s as a fixed constraint, not something the migration improves.

- **Tie `dl_limit` to NAS sustained write, not to link speed.** libtorrent blocks *all* of an instance's other disk I/O while a move runs; if aggregate download rate exceeds the serialized move-drain rate the queue grows without bound (the "days behind" failure mode in #9407). The shipped `dl_limit: 62914560` (60 MB/s) is above the measured ~30 MB/s NAS write — acceptable as an initial ceiling, but **if the qbt-br move queue backlogs on node-02, lower `dl_limit` toward ~30–40 MB/s**. Once `qbt-se` is added, it is the *combined* download rate of both instances that must stay under NAS write throughput — budget per-instance (≈20–25 MB/s each) rather than 60 MB/s each.

- **Dirty-page sysctl is shipped as IaC (no manual step).** The "every co-located pod stalls" symptom is Linux dirty-page writeback throttling, not CPU/RAM/local-disk: with default `vm.dirty_ratio` (~20 % of RAM) the kernel buffers multiple GB destined for a 30 MB/s NAS, then hard-throttles every writer on the node for minutes (the global dirty limit is not per-filesystem, so pods writing to fast local disk get trapped behind the NAS backlog too). Fixed by `ansible/k3s/install-k3s.yaml` → task *"Bound dirty page-cache…"*, which writes `/etc/sysctl.d/99-nfs-writeback.conf`:

  ```
  vm.dirty_background_bytes = 67108864     # 64 MiB — start flushing early
  vm.dirty_bytes            = 268435456    # 256 MiB — hard cap (~8 s drain @30 MB/s)
  vm.dirty_writeback_centisecs = 500
  ```

  The host-prep play targets `k3s_server:k3s_agents`, so **node-02 picks this up automatically** the first time `install-k3s.yaml` runs against it after it's added to `ansible/inventory.ini` — no extra step in this runbook. It also already applies to node-01, which still needs it after cutover because **SABnzbd stays on node-01** and also moves completed files to the same NFS share, so node-01's NAS-writeback pressure does not fully disappear when qbt migrates. Re-running the host-prep play on existing nodes is safe and idempotent (`copy` + `sysctl --system`, no k3s restart).

- **NFS mount options are low-leverage here.** The `media-data` PV sets only `nconnect=4`; effective opts are `vers=3,rsize=wsize=512K,hard,timeo=600,retrans=2`. `nconnect` helps bandwidth-bound mounts, not a disk-bound NAS — it is neither helping nor hurting; leave it. No client mount option fixes a server-side RAID5 + saturated-QLC-cache write ceiling. Leverage is `dl_limit` + the dirty-page sysctl + node isolation, not mount tuning.
