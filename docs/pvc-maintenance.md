# PVC Maintenance

PVCs can't be touched while there are pods bound to them. Services are managed by ArgoCD and are set to `self-heal`, so a few triggers need to be disabled before any changes can be made to PVCs.

## Two-tier ArgoCD app structure (important)

In this repo, **PVCs and Deployments are owned by different ArgoCD Applications**:

- **PVCs** live in the **infra** apps:
  - `media-infra` — all PVCs under `media/`
  - `dashboard-infra` — all PVCs under `dashboard/`
- **Deployments** live in the **per-service** apps (`autobrr`, `sonarr`, `plex`, ...)

So a PVC change requires suspending the matching `*-infra` app. Suspending only the per-service app leaves the PVC reconciled back by the infra app.

Both layers are also reconciled by the root **`media-apps`** App-of-Apps — patches to any child app's `syncPolicy` get reverted by it. Either suspend `media-apps` too, or accept that you'll need to re-suspend the child after each root reconciliation.

## Suspend auto-sync (preferred form)

Don't blank out the whole `syncPolicy` — that drops `syncOptions: [CreateNamespace=true]` and you'll have to put it back. Just remove the `automated` block:

```bash
kubectl -n argocd patch application <app> \
  --type=json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
```

To suspend all PVC owners + the root at once:

```bash
for app in media-apps media-infra dashboard-infra; do
  kubectl -n argocd patch application $app \
    --type=json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
done
```

## Stopping pods safely

After suspending the per-service app (so it won't scale back to 1):

```bash
kubectl -n argocd patch application <app> \
  --type=json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
kubectl -n <namespace> scale deploy/<app> --replicas=0
kubectl -n <namespace> wait --for=delete pod -l app.kubernetes.io/name=<app> --timeout=60s
```

### StatefulSets: check the PVC retention policy before scaling

Scaling a StatefulSet to 0 can **delete its PVC**, and with a `Delete` reclaim
policy that destroys the Longhorn volume and its data. Always check first:

```bash
kubectl -n <namespace> get sts <name> -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy}'
```

`whenScaled: Delete` means scaling to 0 is destructive. Known in this repo:

| StatefulSet                          | `whenScaled` | Scaling to 0 is      |
| ------------------------------------ | ------------ | -------------------- |
| `monitoring/loki`                    | `Delete`     | **destroys the PVC** |
| `monitoring/prometheus-alertmanager` | `Retain`     | safe                 |

This bit on 2026-07-31: scaling `sts/loki` to 0 to free a node for a reboot
deleted `storage-loki-0` and all retained logs.

[`../scripts/rack/shutdown`](../scripts/rack/shutdown) reads `whenScaled` per
StatefulSet and takes the delete-pod path automatically, so a full-rack shutdown
does not need this table consulted by hand.

To take a `whenScaled: Delete` StatefulSet off a node without losing its volume,
**cordon the node and delete the pod** instead of scaling — the replica count
never changes, so the retention policy never fires and the pod reschedules
elsewhere:

```bash
kubectl cordon <node>
kubectl -n <namespace> delete pod <sts-pod>
```

This only works if nothing pins the workload to that node — check
`nodeSelector`/`affinity` first. (`media/plex` is hard-pinned to `k3s-node-02`
for Intel QSV, so it can only be scaled down.)

## Restoring pods / re-enabling auto-sync

Add back only the `automated` block. Don't spell out `syncOptions` in the patch —
a merge patch replaces that array wholesale, and apps don't all carry the same
options (`loki` and `prometheus` have `ServerSideApply=true` on top of
`CreateNamespace=true`, and dropping it silently changes how they sync):

```bash
kubectl -n argocd patch application <app> --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

Check what an app actually has before patching, if in doubt:

```bash
kubectl -n argocd get application <app> -o jsonpath='{.spec.syncPolicy}'
```

Or in the ArgoCD UI: Application → "Enable Auto-Sync".

## Expanding a PVC

Raise `storage:` in `k3s/apps/<ns>/_infra/longhorn-pvcs.yaml` and let Argo apply it.
Longhorn expands the block device, then kubelet grows the filesystem on the next mount
(`FileSystemResizeSuccessful`). Confirm both layers — the PVC's `status.capacity` only
catches up after the filesystem step:

```bash
kubectl get pvc -n <ns> <pvc> -o jsonpath='want={.spec.resources.requests.storage} have={.status.capacity.storage}{"\n"}'
kubectl exec -n <ns> deploy/<app> -- df -h <mountpath>
```

### When it gets stuck

Online expansion needs the engine to refresh the iSCSI initiator on the node. If that
call fails the expansion never completes and `external-resizer` retries forever, while
**every routine health signal stays green** — the volume reads `attached`/`healthy`,
replicas are `running`, backups keep succeeding. Symptoms:

```bash
kubectl get pvc -A -o json | jq -r '.items[]
  | select((.status.conditions//[])[]?.type=="Resizing")
  | "\(.metadata.namespace)/\(.metadata.name) want=\(.spec.resources.requests.storage) have=\(.status.capacity.storage)"'

# engine spec vs current — different, with EngineMonitor looping, means stuck
kubectl get engines.longhorn.io -n longhorn-system -o json | jq -r \
  '.items[]|select(.spec.volumeName=="<vol>")|"spec=\(.spec.volumeSize) current=\(.status.currentSize) im=\(.status.instanceManagerName)"'
```

The instance-manager log names the cause:

```
Failed to expand the frontend … fail to refresh iSCSI initiator: nsenter
  --mount=/host/proc/<pid>/ns/mnt … cannot open …: No such file or directory
```

That PID is `iscsid` as it was when the instance-manager started. If `iscsid` has since
restarted, the cached reference is dangling and **every** online expansion on that node
fails until the instance-manager is replaced. Confirm with
`ssh <node> 'ls -d /proc/<pid>; pgrep -a iscsid'`.

**Scaling the workload down does not fix it, and the volume will not detach.** Longhorn's
`volume-expansion-controller` holds its own attachment ticket in order to perform the
expansion, and only releases it on success — so `expansionRequired: true` and the ticket
keep each other alive. A wait-for-detached loop never returns:

```bash
kubectl get volumeattachments.longhorn.io -n longhorn-system <vol> \
  -o json | jq -r '.spec.attachmentTickets|keys[]'
# volume-expansion-controller-<vol>  ← the holder; no workload involved
```

The fix is to replace the instance-manager holding the engine, which means detaching
every volume on it. In practice that is a full quiesce cycle — `make shutdown` then
`make startup`. On reattach the engine lands on a current instance-manager with a valid
`iscsid` PID and the expansion completes on its own.

Two things to expect during that shutdown:

- The step-2 detach wait will list the stuck volume. It is attached at block level with
  **no mounted filesystem**, so there is no writer and powering off is safe — the script
  now says so explicitly per volume.
- Restarting the instance-manager live instead is possible but takes down every volume it
  hosts, typically a dozen SQLite-backed apps at once. That is the unclean-teardown
  pattern that corrupted databases before; prefer the quiesce cycle.

An expansion left pending is not urgent on its own — the volume keeps working at its old
size. Its real cost is noise: a few hundred errors an hour in the instance-manager log,
plus continuous `external-resizer` retries.

## Restoring a Longhorn-backed PVC from backup

Use this when the current PVC is empty (fresh provision) and you want to swap in data from a Longhorn backup on UNAS-4. The flow re-creates the original Longhorn volume + a pre-claimed PV, so when Argo recreates the PVC it static-binds (no dynamic provisioning).

### Per-volume inputs

You need:

- `NS` — namespace, e.g. `media`
- `PVC` — PVC name, e.g. `autobrr-config-lh`
- `OLD_PV` — original PV name (the `pvc-<uuid>` from before — see `kubectl -n longhorn-system get backupvolumes` → KubernetesStatus labels)
- `SIZE_BYTES` — original volume size in bytes (from `backupvolume.status.size`)
- `SIZE_DISPLAY` — same in K8s form (`1Gi`, `2Gi`, `500Mi`, …)

### 1. Suspend Argo on the matching apps

```bash
for app in media-apps media-infra <per-service-app>; do
  kubectl -n argocd patch application $app \
    --type=json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
done
```

### 2. Scale workload to 0, delete the empty PVC

```bash
kubectl -n $NS scale deploy/<app> --replicas=0
kubectl -n $NS wait --for=delete pod -l app.kubernetes.io/name=<app> --timeout=60s
kubectl -n $NS delete pvc $PVC
```

### 3. Create a Longhorn Volume from the backup

```bash
BV=$(kubectl -n longhorn-system get backupvolume -o json | \
  jq -r ".items[] | select(.metadata.labels.\"backup-volume\"==\"$OLD_PV\") | .metadata.name" | head -1)
BACKUP_NAME=$(kubectl -n longhorn-system get backupvolume "$BV" -o jsonpath='{.status.lastBackupName}')
URL=$(kubectl -n longhorn-system get backup "$BACKUP_NAME" -o jsonpath='{.status.url}')

cat <<EOF | kubectl apply -f -
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: $OLD_PV
  namespace: longhorn-system
spec:
  fromBackup: "$URL"
  numberOfReplicas: 2
  size: "$SIZE_BYTES"
  frontend: blockdev
  dataLocality: best-effort
  accessMode: rwo
  staleReplicaTimeout: 30
EOF
```

Wait for the volume to finish restoring (`restoreInitiated=true && restoreRequired=false`, state `detached`):

```bash
until [[ \
  "$(kubectl -n longhorn-system get volume $OLD_PV -o jsonpath='{.status.restoreInitiated}')" == "true" && \
  "$(kubectl -n longhorn-system get volume $OLD_PV -o jsonpath='{.status.restoreRequired}')" == "false" && \
  "$(kubectl -n longhorn-system get volume $OLD_PV -o jsonpath='{.status.state}')" == "detached" \
]]; do sleep 3; done
```

### 4. Create a PV with the claim pre-set

When the PVC is recreated, it static-binds to this PV instead of dynamically provisioning a new volume.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $OLD_PV
spec:
  capacity:
    storage: $SIZE_DISPLAY
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Delete
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeAttributes:
      numberOfReplicas: "2"
      staleReplicaTimeout: "30"
    volumeHandle: $OLD_PV
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    namespace: $NS
    name: $PVC
EOF
```

### 5. Re-enable Argo (infra first, then per-service)

```bash
# Infra app recreates the PVC, which binds to the pre-claimed PV
kubectl -n argocd patch application <infra-app> --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'

# Per-service app scales the deployment back to 1
kubectl -n argocd patch application <app> --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'

# Re-enable root last
kubectl -n argocd patch application media-apps --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'
```

Verify the PVC bound to the restored PV (not a new dynamic one) and check app logs for restored state:

```bash
kubectl -n $NS get pvc $PVC -o jsonpath='{.spec.volumeName}{"\n"}'  # should be $OLD_PV
kubectl -n $NS logs deploy/<app> --tail=20
```

## Restoring a PVC from a host tarball (Plex pattern)

When you have a fresh local tarball that's newer than the latest Longhorn backup, skip the LH-restore and stream the tarball directly into the empty PVC.

```bash
# 1. Suspend Argo for the per-service app, scale to 0
kubectl -n argocd patch application <app> \
  --type=json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
kubectl -n <ns> scale deploy/<app> --replicas=0
kubectl -n <ns> wait --for=delete pod -l app.kubernetes.io/name=<app> --timeout=60s

# 2. Launch a sleep pod that mounts the (now-empty) PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: <app>-restore
  namespace: <ns>
spec:
  restartPolicy: Never
  containers:
  - name: restore
    image: alpine:3.21
    command: ["sleep","3600"]
    volumeMounts:
    - name: config
      mountPath: /config
  volumes:
  - name: config
    persistentVolumeClaim:
      claimName: <pvc-name>
EOF

# 3. Copy the tarball into the pod (kubectl cp is reliable; piping >1GB through `exec -i` is not)
kubectl -n <ns> cp <local-tarball> <app>-restore:/tmp/restore.tar.gz

# 4. Extract into /config, then clean up
kubectl -n <ns> exec <app>-restore -- sh -c 'cd /config && rm -rf lost+found && tar xzf /tmp/restore.tar.gz && rm /tmp/restore.tar.gz && du -sh /config'
kubectl -n <ns> delete pod <app>-restore

# 5. Re-enable Argo, deployment scales back automatically
kubectl -n argocd patch application <app> --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'
```

`tar` on busybox may emit a benign `short read` at EOF — verify by checking the extracted size matches expectations.

## Adding a PVC to a live app-template chart

Adding a second `persistence` entry to a bjw-s `app-template` chart that currently has
exactly one PVC **renames the existing one**. The chart names a lone PVC after the
release; once there are two, both gain an identifier suffix. Argo sees the old name as
removed, prunes it, and a Longhorn StorageClass with `reclaimPolicy: Delete` destroys
the volume with it.

`global.alwaysAppendIdentifierToResourceName: true` makes the suffix unconditional, so
the name never changes as PVCs are added. Set it on **new** charts only — switching it
on for a live single-PVC app renames that PVC and triggers exactly the deletion it
prevents.

Before adding a PVC to an existing chart, `helm template` it and diff the rendered PVC
names against `kubectl get pvc -n <ns>`. If a name changes, migrate the data first.
