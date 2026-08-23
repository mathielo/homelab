---
description: Health sweep of the k3s cluster (firing alerts, node metrics, pods, resource balance, ArgoCD, Longhorn, per-app logs, warnings) — read-only against infra; may apply resource sizing to values.yaml when the repo is clean
argument-hint: "[log window, e.g. 1h, 6h — default 1h]"
allowed-tools: Bash(kubectl get:*), Bash(kubectl top:*), Bash(kubectl logs:*), Bash(kubectl describe:*), Bash(kubectl exec:*), Bash(ssh:*), Bash(git status:*), Bash(git diff:*), Bash(jq:*), Bash(grep:*), Bash(sed:*), Bash(awk:*), Bash(echo:*), Bash(printf:*), Bash(date:*), Bash(tail:*), Bash(head:*), Bash(cut:*), Bash(sort:*), Bash(uniq:*), Bash(for:*), Read, Edit
---

Run an on-demand health check of the homelab k3s cluster and give me a structured
report. Log scan window: `$1` (default `1h` if empty).

**The infrastructure is strictly read-only**: `kubectl get`/`top`/`logs`/`describe`/
`exec` of read commands, and read-only `ssh` OS inspection. No `apply`/`edit`/`patch`/
`scale`, no writes through any app's API, nothing changed on a node.

The one thing this check may write is the **repo working tree**, and only under §3's
sizing gate — resource requests and limits in `values.yaml`, when the tree is clean.
That is proposing a change as code, which is how every change here is made; it is not
touching the running cluster. Never `git add`/`commit`/`push`.

Run the checks below (batch independent commands in parallel), then **interpret**
the results — don't just dump raw output. Apply judgment: separate real problems
from known-benign noise. The standing goal is a **warning-free environment**, so
actively hunt warnings and, for each, decide whether it's fixable or must be
accepted (see §8).

## 0. Firing alerts (start here)

The cluster's Prometheus alert rules (defined in
`k3s/apps/monitoring/prometheus/values.yaml` — node/disk/PVC, Longhorn, SMART
temperature & health, ingress, cert expiry, Pi-hole HA) are the authoritative
statement of what "unhealthy" means here, so read it before hand-rolling any
threshold below:

```
kubectl exec -n monitoring deploy/prometheus-server -c prometheus-server -- \
  wget -qO- 'localhost:9090/api/v1/query?query=ALERTS' \
  | jq -r '.data.result[]|"\(.metric.alertstate)\t\(.metric.severity)\t\(.metric.alertname)\t\(.metric.node // .metric.pod // .metric.device // "-")"' | sort -u
```

Every **firing** alert goes into the §8 table — a report that says 🟢 while an
*unassessed* alert is firing is wrong. `pending` ones are leads worth naming.

An alert listed in §8's **standing accepted conditions** is the exception: it is
already assessed, so it does not force the verdict down. Report it on one line
(`🟢 healthy — 1 standing: DAS disk temps`) and move on. Re-litigating the same
accepted alert every run is the noise this check exists to remove — but do check its
**re-open trigger**, which is the whole point of writing one down.

This section also keeps the skill honest, in both directions:

- **A firing alert that no §1–§7 check would have caught** = a blind spot in this
  file. Name it and propose the check.
- **A threshold in this file with no matching alert rule** = a gap in monitoring;
  this check only runs when the user runs it, an alert rule runs always. Propose the
  rule for `prometheus/values.yaml`.

Prometheus also answers questions this sweep otherwise guesses at — SMART drive
temperatures (`smartctl_device_temperature`), CPU throttling, memory peaks. Retention
is **15d**, so any "is this normal or new?" question is answerable, not speculative.

## 1. Node metrics (structured, glanceable, comparable between runs)

`kubectl top nodes` gives CPU/mem from metrics-server, but pressure has more
angles. SSH each node (`k3s-server`, `k3s-node-01`, `k3s-node-02`) read-only and
gather load, CPU busy, iowait, block I/O, memory, and per-mount disk usage.
`iostat`/`mpstat` are NOT installed — use `vmstat`/`free`/`/proc` (they are):

```
for h in k3s-server k3s-node-01 k3s-node-02; do echo "### $h"; ssh -o ConnectTimeout=5 "$h" \
  'cores=$(nproc); load=$(cut -d" " -f1-3 /proc/loadavg); v=$(vmstat 1 2 | tail -1);
   usr=$(echo $v|awk "{print \$13}"); sys=$(echo $v|awk "{print \$14}"); wa=$(echo $v|awk "{print \$16}");
   bi=$(echo $v|awk "{print \$9}"); bo=$(echo $v|awk "{print \$10}");
   mem=$(free -m|awk "/^Mem:/{printf \"%d/%dMi (%d%%)\",\$3,\$2,\$3*100/\$2}");
   echo "cores=$cores load=[$load] cpu_busy=$((usr+sys))% iowait=${wa}% blk_in=${bi} blk_out=${bo} mem=$mem";
   df -h -x tmpfs -x devtmpfs -x overlay -x efivarfs --output=target,size,used,pcent | tail -n +2 | grep -vE "/boot/efi"'; echo; done
```

Render **two tables** so runs can be eyeballed side by side. Lead **every row**
with a **Status** column — 🟢 ok / 🟡 warning / 🔴 critical / ⚪ by-design (looked
at, but the threshold doesn't apply here) — so the state of each node/mount is
scannable at a glance (a row's status = its worst breached metric):

- **Compute** — one row per node: `Status | Cores | Load 1/5/15 | Load÷core | CPU busy% | iowait% | Blk I/O in/out | Mem`.
  `Load÷core` (load15 ÷ cores) is the real saturation signal, not raw load.
- **Disk** — one row per mount (`Status | Mount | Size | Used | Use%`) for `/`,
  `/boot`, `/mnt/nvme/longhorn`, and the node-specific `/mnt/ssd/local`,
  `/mnt/nvme/local`, `/mnt/r0` per docs/hardware.md. **`/mnt/r0` (k3s-node-02)
  is intentionally kept near full — that's its designed usage. Always render it
  ⚪ regardless of Use%; never 🟡/🔴 and never carry it to the §8 warnings sweep.**

Then a second read-only pass for the things `df` and `load` cannot show — stalled
mounts and real saturation:

```
for h in k3s-server k3s-node-01 k3s-node-02; do echo "### $h"; ssh -o ConnectTimeout=5 "$h" \
  'echo "psi_cpu=$(awk "/some/{print \$3}" /proc/pressure/cpu) psi_io=$(awk "/some/{print \$3}" /proc/pressure/io) psi_mem=$(awk "/some/{print \$3}" /proc/pressure/memory)";
   echo "dstate_procs=$(ps -eo stat= | grep -c "^D")";
   grep " nfs " /proc/mounts | awk "{print \$2}" | grep -v kubelet'; done
```

- **PSI over load** — `/proc/pressure/*` `avg60` is the honest saturation signal.
  **k3s-server's load average lies**: it spikes to 10–20 with CPU idle, zero iowait
  and flat PSI (thread-churn artifact). On that node, judge by PSI and `CPU busy`,
  and never open a §8 warning on `Load÷core` alone. On node-02 the load is real.
- **`dstate_procs` > 0 with `/mnt/nas/media` present** — the wedged-`hard`-NFS-mount
  failure mode. Uninterruptible processes survive `kill -9`; symptoms are node-wide
  slowness and high iowait, not one sick pod. 🔴 — the fix is at the NAS/mount end,
  not in k8s. **Do not `ls`, `df` or `stat` the wedged mount to confirm** — that
  hangs the check too. `/proc/mounts` and PSI are enough.

Flag with thresholds (these are warnings — carry to §8):
`Load÷core` 🟡 >1.0 / 🔴 >2.0 sustained (⚪ on k3s-server, see above) ·
`PSI io avg60` 🟡 >20 · `dstate_procs` 🔴 >0 · `CPU busy` 🟡 >85% · `iowait` 🟡 >20% ·
`Mem` 🟡 >90% · `Disk` 🟡 ≥85% / 🔴 ≥90% (except `/mnt/r0` — always ⚪, see
above). The 40 GiB `/` partitions trend high (containerd image cache in
`/var/lib/k3s/agent`); note ≥85% but know kubelet image-GC self-prunes at the
high threshold (85%, set in `ansible/k3s/install-k3s.yaml`).

## 2. Node conditions & pods

- `kubectl get nodes -o wide`; flag any `*Pressure=True` or not `Ready`.
- `kubectl get pods -A`; flag anything not `Running`/`Completed`
  (CrashLoopBackOff, Pending, Error, OOMKilled, ImagePullBackOff).
- **Restarts:** list containers with `lastState.terminated.finishedAt` in the
  last ~24h (`kubectl get pods -A -o json | jq`). Old restart counts that all
  trace to a single past timestamp = a prior planned reboot, **not** churn — say
  so rather than alarming. Only recent/repeating restarts matter. Note the
  `reason` — an **OOMKilled** terminated-state feeds §3 (real mem-limit pressure).
- **Pending kernel reboot:** the k3s nodes install security updates unattended but
  never reboot themselves — an unattended reboot tears Longhorn volumes off
  mid-write (§5), so the reboot is deferred to `make shutdown` / `make startup`.
  That safety costs visibility: a node can sit for weeks on a superseded kernel and
  nothing in `kubectl` shows it, so read the marker file directly.

  ```
  for h in $(kubectl get nodes -o name | cut -d/ -f2); do printf '%-14s %s\n' "$h" \
    "$(ssh $h 'cat /var/run/reboot-required.pkgs 2>/dev/null | tr "\n" " "' || echo none)"; done
  ```

  Discover the hosts from `kubectl` rather than listing them — node names are the
  SSH host names. 🟡 once a node has been pending more than a week; 🔴 when the
  pending set includes `linux-image-*` **and** the booted kernel is behind the newest
  installed one (`ssh $h 'uname -r; ls -1 /boot/vmlinuz-*'`), because the security fix
  that prompted the update is not actually running. Report it as scheduled work with
  the quiesced-reboot command — never suggest rebooting the node in place.

**Silent failures** — `Running` and `0 restarts` is not proof of health. Three known
modes here present as a perfectly green pod, so check for them explicitly:

- ***arr s6 self-restart bind loop*** — the in-app Restart button orphans the process
  and s6 respawns a doomed instance every ~4.5 s **forever**. Pod stays `1/1 Running`,
  restarts `0`, `/ping` returns 200; only ~0.7 cores of CPU and a flood of identical
  log lines give it away. Any *arr sitting at high steady CPU with a repeating startup
  line in §6 is this. Fix: `kubectl rollout restart` (never the UI Restart button).
- **gluetun port-forward drop** (`qbt-*`) — ProtonVPN forwarded ports **never
  auto-recover** once dropped, and the container reports healthy throughout. Compare
  gluetun's forwarded port against what qBittorrent is actually listening on:

  ```
  for q in qbt-se qbt-br qbt-mam; do echo -n "$q "; \
    kubectl exec -n media deploy/$q -c gluetun -- cat /tmp/gluetun/forwarded_port; \
    kubectl exec -n media deploy/$q -c main -- wget -qO- localhost:8080/api/v2/app/preferences | jq .listen_port; done
  ```

  Read the **file**, not the control API: gluetun ≥3.40 requires auth on `:8000`, so
  `wget localhost:8000/v1/...` exits 6 rather than answering. A mismatch is 🟡 fixable
  (`vpn-port-healer` handles rotation, but confirm it acted).

  `gluetun`, `vpn-port-healer` and `cleanup-stale-lock` are **native sidecars**
  (initContainers with `restartPolicy: Always`). `kubectl exec -c <name>` reaches them,
  but anything reading `.spec.containers[]` does not — see §3.
- **Wedged NFS mount** — surfaces as slow pods on one node, not as a pod condition.
  Caught in §1, not here.

## 3. Resource right-sizing (requests/limits balance)

**First, the node view.** Per-container ratios say nothing about whether a node can
survive its own pods all peaking at once — the question that actually matters when
raising a limit:

```
for n in k3s-server k3s-node-01 k3s-node-02; do echo -n "$n: "; \
  kubectl describe node "$n" | awk '/Allocated resources/,/Events/' | grep -E "^  (cpu|memory)" | tr '\n' ' '; echo; done
```

Report a **per-node allocation table** (`Status | Node | RAM | Requests | Limits % |
Verdict`). Requests are the scheduler's contract and must stay under 100%. Limits
routinely exceed 100% — that is normal overcommit — but the *ratio* is the blast
radius: node-02 currently sits at **208 % of RAM in limits**, so a handful of
containers peaking together will OOM something. State the number before proposing any
limit increase, and prefer raising a **request** (scheduling truth) over a **limit**
(ceiling) on a node already deep in overcommit.

Then the per-container view: catch containers that are **starved** (near their limit,
or using more than they request) or **bloated** (reserving far more than they ever
touch). Two data sources, joined per `namespace/pod/container`:

- **Live usage** (metrics-server snapshot — millicores + MiB):
  `kubectl top pods -A --containers --no-headers`
- **Configured requests/limits** — `(.spec.containers[], .spec.initContainers[]?)`,
  because `.spec.containers[]` alone drops every native sidecar (`gluetun`,
  `vpn-port-healer`, `cleanup-stale-lock`), and `kubectl top --containers` omits them
  too. Their usage is only visible through the Prometheus queries below, so check
  sidecar throttling there rather than trusting the join to list them:
  `kubectl get pods -A -o json | jq -r '.items[]|.metadata.namespace as $ns|.metadata.name as $p|(.spec.containers[], .spec.initContainers[]?)|[$ns+"/"+$p+"/"+.name,(.resources.requests.cpu//"-"),(.resources.limits.cpu//"-"),(.resources.requests.memory//"-"),(.resources.limits.memory//"-")]|@tsv'`

Join them (awk on the `ns/pod/container` key, no temp files) and, per container,
reason about `mem %R = use/request`, `mem %L = use/limit`, and `cpu %R = use/request`:

```
awk -F'\t' 'NR==FNR{r[$1]=$2" "$3" "$4" "$5; next} ($1 in r){print $1"\t"$2"\t"$3"\t"r[$1]}' \
  <(kubectl get pods -A -o json 2>/dev/null | jq -r '.items[]|.metadata.namespace as $ns|.metadata.name as $p|(.spec.containers[], .spec.initContainers[]?)|[$ns+"/"+$p+"/"+.name,(.resources.requests.cpu//"-"),(.resources.limits.cpu//"-"),(.resources.requests.memory//"-"),(.resources.limits.memory//"-")]|@tsv' | sort) \
  <(kubectl top pods -A --containers --no-headers 2>/dev/null | awk '{print $1"/"$2"/"$3"\t"$4"\t"$5}' | sort)
```
(columns: `key  cpu_use  mem_use  cpu_req cpu_lim mem_req mem_lim`)

Verdicts — surface only containers worth attention (don't dump all ~60). Present a
table `Status | ns/pod/container | CPU use/req | Mem use/req/lim | mem %R | mem %L | Verdict`:

- 🔴 **Memory near limit** — `mem %L ≥ 90%`, or any container with an **OOMKilled**
  history (from §2). Real OOM risk → **raise the mem limit**. OOMKilled is the
  definitive signal; a high snapshot alone is only a lead.
- 🟡 **Under-requested memory** — `mem %R > 100%` (using more than it reserves).
  The scheduler under-counts it and it's first to be evicted under node pressure
  → **bump the mem request** toward real steady usage.
- 🟡 **Under-requested CPU** — `cpu %R` persistently ≫ 100% on a latency-sensitive
  service (not a batch/burst job) → nudge the CPU request up.
- 🟡 **Over-provisioned (waste)** — `mem %R < 20%` **and** `cpu %R < 10%` on a
  steady service → it hoards schedulable capacity it never uses; propose trimming
  the request (esp. CPU: a 500m request idling at 5m). An optimization, not a
  fault — list it, don't count it against warning-free.
- ⚪ **No requests/limits set** — note containers missing a mem request (unbounded
  scheduling) or mem limit (can starve neighbours); tiny sidecars may be
  intentionally unset — judge, don't blanket-flag.

**Do NOT flag as over-provisioned** the workloads whose high ceilings are
**deliberate burst headroom** (the limit is a spike ceiling, not steady demand):
`qbt-*` main + `gluetun` sidecars, `plex`, `sabnzbd`, and any container whose
values.yaml comment marks the size as intentional. Over-provisioning flags target
steady low-usage services (arr apps, small web UIs) with fat requests.

**Never size off the snapshot.** `kubectl top` is one instant; a limit set from it is
a guess. Prometheus holds 15d — use the **7d peak**, which is the number the limit
actually has to clear:

```
kubectl exec -n monitoring deploy/prometheus-server -c prometheus-server -- wget -qO- \
  'localhost:9090/api/v1/query?query=topk(20,max_over_time(container_memory_working_set_bytes{container!=""}[7d])/1024/1024)' \
  | jq -r '.data.result[]|"\(.metric.namespace)/\(.metric.pod)/\(.metric.container)\t\(.value[1]|tonumber|floor)Mi"'
```

CPU pressure has an equivalent, and it beats `cpu %R` as evidence — throttling is the
symptom a CPU limit actually causes:

```
  'localhost:9090/api/v1/query?query=topk(10,rate(container_cpu_cfs_throttled_periods_total{container!=""}[6h]))'
```

Quote **snapshot _and_ 7d peak** in the table so the gap between them is visible (a
container idling at 200 Mi that peaked at 8 Gi is not over-provisioned). Propose
`request ≈ steady`, `limit ≈ peak + headroom`, and name the exact `values.yaml` and
number. Carry 🔴 near-limit and 🟡 under-request rows into the §8 sweep as 🔧
fixable; keep over-provisioning as a separate optimization note.

### Applying the sizing changes

**Gate first — a clean working tree is the precondition:**

```
git -C <repo> status --porcelain
```

**Empty output → edit the `values.yaml` files directly** with the numbers from the
table. Non-empty → **change nothing**; report the proposal as a diff to apply by hand
and say which paths are dirty. The gate exists so the sizing edits land as a
reviewable standalone diff instead of tangling with work already in progress.

What may be applied this way is deliberately narrow:

- **Only `resources:` requests and limits.** Never images, replicas, probes, args, or
  anything else surfaced by the run.
- **Only numbers corroborated by the 7d peak**, never by the `kubectl top` snapshot
  alone. No history, no edit.
- **Never on a node already deep in limit overcommit** without saying so — raise the
  **request** there, and flag the limit increase for the user to decide.

After editing, run `git -C <repo> diff` and put it in the report: the run must show
exactly what it changed. Then stop. **Do not `git add`, commit, push, or apply
anything to the cluster** — Argo syncs from the repo, the user reviews and commits,
per the repo's GitOps and git-ownership policies. An applied edit is still a
*proposal*, one that happens to already be written down.

## 4. ArgoCD

`kubectl get applications -n argocd` with sync + health columns; flag anything
not `Synced` + `Healthy`.

## 5. Longhorn (treat as critical — history of unclean-shutdown DB corruption)

Volume `robustness`/`state` (flag non-`healthy`/non-`attached`); confirm the
recurring `backup`/`snapshot` **job** pods reached `Completed`. Match the
timestamped job pods only (`grep -E 'daily-backup-|snapshot-[0-9]'`) — NOT the
always-`Running` `csi-snapshotter` controller pods.

**`robustness: healthy` does not mean the data is intact.** Longhorn reports on the
block device; it replicates a corrupted filesystem just as faithfully as a good one,
so a volume whose ext4 was destroyed by an unclean detach still shows
`attached`/`healthy` with every replica `Running`. The damage surfaces one layer up,
as a pod that never starts:

```
LIVE=$(kubectl get pods -A -o json | jq -c '[.items[]|.metadata.namespace+"/"+.metadata.name]')
kubectl get events -A --field-selector reason=FailedMount -o json \
| jq -r --arg t "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" --argjson live "$LIVE" '
  .items[] | select((.eventTime // .lastTimestamp // .firstTimestamp) > $t)
  | (.involvedObject.namespace + "/" + .involvedObject.name) as $p
  | select($live | index($p))
  | "\($p)\t\(.message)"' | grep -i fsck
```

Both filters are load-bearing, and **the time bound alone is not enough**: an event
stays retained after its pod is gone and keeps its recent timestamp, so a volume
repaired ten minutes ago still reports a `FailedMount` inside any sane window. The
`$live` join is what distinguishes a resolved incident from a current one — a hit
naming a pod that no longer exists is history, not a finding.

Any `UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY` for a **current** pod is 🔴 regardless
of what the volume list says, and it is not self-healing — replica rebuild copies the damage.
Recovery is `e2fsck` on the attached-but-unmounted device
(`docs/storage-longhorn.md` → "Corrupted volume"). Because it takes a mount to notice,
this can stay latent for days: a `FailedMount` naming files whose mtimes predate the
last reboot means the corruption is older than the reboot that exposed it, and the
snapshots from that window carry it too — say so, so nobody restores onto the same damage.

A `Completed` job pod only proves the job ran. An individual volume can fail inside a
job that still reports success, so check the **volumes**, two ways:

```
kubectl exec -n monitoring deploy/prometheus-server -c prometheus-server -- wget -qO- \
  'localhost:9090/api/v1/query?query=(time()-longhorn_volume_last_backup_at)/3600' \
  | jq -r '.data.result[]|"\(.metric.pvc_namespace)/\(.metric.pvc)\t\((.value[1]|tonumber)|floor)h"' | sort -k2 -rn
```

- **Errors** — the most direct signal, and the one age and job-status both miss.
  Check it first:

  ```
  kubectl get backups.longhorn.io -n longhorn-system -o json \
    | jq -r '.items[]|select(.status.state=="Error")|"\(.metadata.creationTimestamp)\t\(.status.error[0:160])"'
  ```

  `failed to write data during saving blocks: close ...` means the backup target's
  `soft` NFS mount hit its timeout budget mid-write and returned EIO. It scales with
  volume size, so the **largest** volume fails while every other volume in the same
  run succeeds — a partial failure that leaves the job `Completed`. `retrans=5` on the
  target widens the budget (`ansible/k3s/files/longhorn.values.yaml`); `hard` would
  remove the limit but risks an unkillable D-state wedge on the NAS mount. Full
  failure mode in `docs/storage-longhorn.md` → "Silently skipped volumes".

  *Pending decision (2026-08-23):* an alert on `longhorn_backup_state == Error` would
  catch this at 22:30 instead of 06:00, but `retrans=5` was applied the same day and
  may remove the failure entirely. **Re-evaluate after 2026-08-30:** if any volume has
  errored again since, add the rule to `prometheus/values.yaml`; if the week is clean,
  delete this note.
- **Age** — against the schedule (`daily-backup` 00:15, `weekly-backup` Sun 00:30,
  `monthly-backup` 1st 00:45, `snapshot-6h`). `LonghornVolumeBackupStale` alerts on
  this at 30h, so §0 normally catches it first — but note it fires ~8h *after* the
  failed run, and cannot fire at all for a volume whose previous night succeeded
  inside the 30h window. Treat it as a backstop, not the primary detector.
- **Gaps** — count *distinct volumes backed up per day* over the last week. A day
  whose count dips below its neighbours means specific volumes were skipped while the
  job still reported Completed, and the newest-backup timestamp stays green.

  **Bucket by local date, not UTC.** The jobs run 00:15 local and the cluster is
  `+0200`, so every nightly backup carries a `22:15Z` timestamp belonging to the
  *previous* UTC day. Slicing `snapshotCreatedAt[0:10]` puts the whole run in the day
  before and makes the current day look empty — which reads as a total backup
  failure when nothing is wrong.

  ```
  day() { kubectl get backups.longhorn.io -n longhorn-system -o json \
    | jq -r '.items[]|"\(.status.snapshotCreatedAt)\t\(.status.volumeName)"' \
    | while read -r ts vol; do [ "$(date -d "$ts" +%F)" = "$1" ] && echo "$vol"; done | sort -u; }
  for d in $(seq 7 -1 0); do d=$(date -d "$d days ago" +%F); echo "$d $(day $d | wc -l)"; done
  ```

  A count that *matches* its neighbour is not proof the same volumes ran — the set can
  change while the size holds. Diff two days to name what was dropped, then map the
  volume back to its PVC:

  ```
  comm -23 <(day "$(date -d yesterday +%F)") <(day "$(date +%F)")
  kubectl get volumes.longhorn.io -n longhorn-system <vol> -o jsonpath='{.status.kubernetesStatus.pvcName}'
  ```

Also watch longhorn-manager for `Failed to get backupInfo from remote backup target`
(§6): a backup record on the NFS target that cannot be read is retried every ~10 min
forever, and it names the volume it belongs to.

**Volumes on the `longhorn-no-bkp` StorageClass have no backups _by design_** — they
hold disposable monitoring data and were deliberately excluded. Render them ⚪;
flagging them as missing-backup is a **false positive**, not a finding. Enumerate
them rather than trusting a written list, which goes stale as volumes come and go:

```
kubectl get pv -o json | jq -r '.items[]|select(.spec.storageClassName=="longhorn-no-bkp")|"\(.spec.claimRef.namespace)/\(.spec.claimRef.name)"'
```

## 6. Log scan (window `$1`) — every app, with frequency

**Pass 1 — the sweep.** One Loki query covers *every* namespace, so a new or renamed
app cannot fall off the list, and it returns a **count per app**, which is what §8's
Frequency column needs. Coverage is every namespace — `dashboard`, `tools`,
`metallb-system` and `kube-system` included, not just the app-heavy ones.

```
W=${1:-1h}
Q='sum by (namespace, app) (count_over_time({namespace=~".+"} |~ "(?i)(error|fatal|panic|warn)" ['"$W"']))'
kubectl exec -n monitoring deploy/grafana -c grafana -- wget -qO- http://loki:3100/loki/api/v1/query \
  --post-data="query=$(printf %s "$Q" | jq -sRr @uri)" \
  | jq -r '.data.result[]|"\(.value[1])\t\(.metric.namespace)/\(.metric.app)"' | sort -rn
```

**Every app with a non-zero count gets triaged — including the ones whose count looks
"normal".** A steady 60/h of the same benign line is still noise worth fixing at the
source (log level, probe interval, a stale config the app is complaining about). The
goal is a **quiet** log, not merely a fault-free one: noise is what hides the one line
that matters. Work down the list by count.

**Pass 2 — the drill-down.** For each app that surfaced, read the actual lines,
ranked by repetition:

```
kubectl logs -n "$ns" "$pod" --all-containers --prefix --since="$1" 2>/dev/null \
  | sed 's/\x1b\[[0-9;]*m//g' \
  | grep -iE '\b(error|fatal|panic|warn(ing)?)\b|level=(error|warn)|"level":"(error|warn|fatal)"|[[:space:]]E[0-9]{4}[[:space:]]|\[(error|crit)\]' \
  | grep -ivE '"error":null|error=null|level=info|caller=metrics\.go|warnings\.go|is deprecated|"GET |"POST |HTTP/[12]' \
  | sed 's/[0-9]\{4\}-[0-9-]*T[0-9:.]*Z\?//g' | sort | uniq -c | sort -rn | head -10
```

`uniq -c` ranks distinct messages by how often they repeat (the `sed` strips
timestamps so identical events collapse). A message seen once and a message seen
4 000 times need different responses, so the count must survive into §8.

Match on **log-severity markers**, not bare substrings (`fail` matches the
`failed_only` query param in nginx access logs; `error` matches `"error":null`).

If Loki is down, fall back to Pass 2 across every namespace from `kubectl get ns`
(not a hardcoded list) and say in the report that the sweep ran degraded.

## 7. Pi-hole HA (dual resolver + VIP)

Pi-hole runs active/standby on `pihole-01` (`.51`/`::51`, normal master) and
`pihole-02` (`.52`/`::52`), sharing keepalived VIPs `10.10.53.53` / `::53`. SSH
both (read-only) and confirm a healthy one-master / one-backup state:

```
for h in pihole-01 pihole-02; do echo "### $h"; ssh -o ConnectTimeout=5 "$h" '
  for s in pihole-FTL unbound keepalived; do printf "%s=%s " "$s" "$(systemctl is-active $s)"; done; echo
  ip -4 addr show eth0 | grep -q 10.10.53.53 && v4=MASTER || v4=backup
  ip -6 addr show eth0 | grep -q 1c35::53 && v6=MASTER || v6=backup
  echo "vip_v4=$v4 vip_v6=$v6"
  dig +short +time=2 +tries=1 @127.0.0.1 pi.hole >/dev/null 2>&1 && echo "FTL_answering=yes" || echo "FTL_answering=NO"
  echo "nebula-sync=$(systemctl is-active nebula-sync 2>/dev/null)"'; echo; done
```

Flag (carry breaches to §8). Healthy = exactly one node holds each VIP, both FTL
answering, and `nebula-sync` active on pihole-01 only (inactive/not-found on
pihole-02 is correct):

- 🔴 **No master** — neither node holds a VIP: DNS is down network-wide.
- 🔴 **Split-brain** — both hold the same VIP: IP conflict.
- 🔴 **FTL not answering** on a node whose process is `active` — the wedged-FTL
  failure mode (often after a heavy nebula-sync); `sudo systemctl restart pihole-FTL` there.
- 🟡 **Failover active** — pihole-02 holds the VIP (pihole-01 is normally master):
  pihole-01 or its FTL is down; investigate why it didn't preempt back.
- 🟡 **v4/v6 split** — the two VIPs sit on different nodes (the sync group should
  keep them together).
- 🟡 **nebula-sync** not `active` on pihole-01, or its last run failed
  (`journalctl -u nebula-sync -n 20`): replica config drifts.

## 8. Warnings sweep & assessment (the headline section)

Aim: warning-free. Aggregate **every** warning from all sources — the firing
Prometheus alerts from §0, the k8s warning events **bounded to the window**, the
WARN/ERROR log lines from §6 **with their counts**, the metric-threshold breaches
from §1, the silent failures from §2, the near-limit / under-request rows from §3,
and the Pi-hole HA breaches from §7 — then assess each one.

Events must be time-filtered explicitly. `kubectl get events` returns the full
retained history, and events from the `events.k8s.io` API carry `lastTimestamp: null`
(the timestamp lives in `eventTime`), so sorting or filtering on `lastTimestamp`
silently keeps them. Unfiltered, an 11-day-old `ImageGCFailed` and a cordon-storm of
`FailedScheduling` from the last rack maintenance both read as current problems:

```
kubectl get events -A --field-selector type=Warning -o json | jq -r --arg t "$(date -u -d '12 hours ago' +%Y-%m-%dT%H:%M:%SZ)" '
  .items[] | (.eventTime // .lastTimestamp // .firstTimestamp) as $ts
  | select($ts != null and $ts > $t)
  | "\($ts)\t\(.reason)\t\(.involvedObject.namespace)/\(.involvedObject.name)\t\(.count // .series.count // 1)x\t\(.message[0:100])"' | sort
```

(substitute the run's window for `12 hours ago`.) Present a table:

`Source | Warning | Frequency | Assessment`

where Assessment is one of: **🔧 fixable** (give the concrete GitOps fix to propose),
**✅ accept** (known-benign; say why), or **⚪ standing** (a real condition already
accepted with an exit trigger — see below; it gets one summary line, not a row).

Fill **Frequency** from the §6 counts, not impressions — "60/h" and "1 in the window"
get different verdicts. **High-volume benign noise is itself a 🔧 finding**: propose
the log-level or config change that quiets it, rather than growing the accept-list
forever. A line only earns ✅ accept when it is both benign *and* unfixable upstream.

Drop the known-benign lines below before reporting — they're already assessed as
accept:

- nginx `upstream timed out` on `/api/events?stream=` / IRC SSE — an open
  autobrr/UI browser tab hitting the 60s read-timeout, not a fault.
- autobrr `debug` filter "rejected"/rate-limit lines — working as intended.
- nginx access-log lines (HTTP requests with 2xx/3xx status) — not errors; they
  also contain apikeys, so never echo them into the report. **This generalizes: never
  echo secret material into the report.** Container env (`*_VAR_*`, `*_KEY`, `*_TOKEN`,
  `*_PASSWORD`) holds live credentials in plaintext, so when a config check needs one,
  grep for that single variable instead of dumping the block:
  `kubectl -n <ns> get deploy <d> -o jsonpath='{...}' | grep ALLOWED_HOSTS`.
- loki query-stats (`caller=metrics.go`, `level=info`) and coredns `[INFO]`
  query logs — verbose telemetry, not faults.
- `loki-canary` `tail max duration limit exceeded` — canary recycling its tail.
- k8s API deprecation `Warning:` lines (`v1 Endpoints is deprecated`) from
  longhorn-manager/controllers — upstream chatter, not a cluster fault.
- gluetun (qbt/sabnzbd VPN sidecars) `WARN [dns] ... connection reset by peer` /
  `renewing dead connection` to Quad9 `:853` — transient DoT hiccups gluetun
  self-heals. Flag only if persistent or downloads are stalling.
- `csi-snapshotter` `could not find the requested resource (...VolumeSnapshot*)`
  — k8s external-snapshotter CRDs aren't installed; Longhorn backups use their
  own path and are unaffected.
- **qui** orphan-scan runs showing `failed` on `qbt-br` — cosmetic: qui has no
  `/local` mount and br always has active downloads, and qui marks any run with walk
  errors and zero orphans as failed. Not fixable via Ignore Paths; never mount
  `/local` into qui.
- **coredns** `[INFO]`/`[WARNING]` query-log lines (tens of thousands per hour) —
  query logging is deliberately on. It dominates every Loki count; rank it, then set
  it aside.
- **pulsarr** `ERROR: [WATCHLIST_WORKFLOW] Failed to fetch RSS feed` (≈0.7% of
  polls) — Pulsarr polls the Plex watchlist RSS (`rss.plex.tv`, S3-backed) every
  ~10 s with a hardcoded 30 s timeout; occasional Plex-side latency trips it.
  The endpoint is reachable from the pod and the 120-min full reconciliation (a
  separate path) always succeeds, so nothing is missed. Timeout + ERROR severity
  are hardcoded upstream — not config-fixable; **accept**. Only escalate if full
  reconciliation also starts failing.

### Standing accepted conditions

Separate from the benign log lines above: **real** conditions, knowingly accepted for
now, each with an explicit trigger that ends the acceptance. Report them as a
one-line summary, not as fresh findings — but evaluate every re-open trigger on every
run, and if one fires, it leaves this table and becomes a 🔴 finding.

| Since      | Condition                                              | Why accepted                                                                                     | Re-open when                                                                                                                                      |
| ---------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-08-19 | `DiskTemperatureHigh` firing on DAS drives `sda`/`sdb` | Enclosure airflow is at its practical limit; a lower steady temperature needs a physical rebuild | `DiskTemperatureCritical` (>60 °C) fires · `DasDiskLatencyImbalance` fires · any reallocated/pending sector appears · steady state exceeds ~58 °C |

Baseline for that row (so drift is detectable rather than a fresh surprise): steady
**52–54 °C**, 7d max **58–60 °C**, SMART otherwise clean. Quote the current numbers
against that baseline in the one-liner — an accepted condition still gets measured.

Adding a row here is a deliberate act: it needs the re-open trigger and the baseline,
otherwise it is not an acceptance, it is a blind spot.

Permanent by-design exemptions — `/mnt/r0` running near full, k3s-server's phantom
load — belong inline as ⚪ in their own section, not here. This table is only for
conditions that are meant to end.

Surface anything that survives this filter (e.g. repeated `x509`/auth failures,
OOMKills, real `panic`, a *new* app erroring, a disk crossing 90%).

## Output

Use the 🟢 / 🟡 / 🔴 traffic-light system everywhere state is reported (verdict,
table rows, per-area lines) so status is scannable at a glance — plus ⚪ for
by-design rows that are deliberately exempt from their threshold (e.g.
`/mnt/r0`). Use ⚠️ inline when calling out a specific warning in prose.

1. One-line **verdict** (🟢 healthy / 🟡 N warnings / 🔴 issues) — it can never be
   🟢 while an unassessed Prometheus alert from §0 is firing. Standing accepted
   conditions ride along in the same line: `🟢 healthy — 1 standing (DAS temps 52/54 °C)`.
2. **Firing alerts** from §0, if any: alert name, target, severity — with the
   standing ones grouped and labelled ⚪, so what's *new* stands out from what's known.
3. The two **node-metrics tables** from §1 (the glanceable part), each row led by
   its 🟢/🟡/🔴 Status column, plus the **per-node allocation table** from §3.
4. Short **per-area** lines (pods / ArgoCD / Longhorn) each prefixed with a
   🟢/🟡/🔴 marker.
5. The **per-app log table** from §6 — every app with a non-zero count, its count,
   and the top repeated message. This is the section that catches slow rot.
6. The **resource right-sizing table** from §3 — 🔴 near-limit and 🟡
   under-request rows first (with snapshot, 7d peak, the exact `values.yaml` and the
   suggested number), then any over-provisioned trims as optimizations. Skip the
   section only if nothing is off in either direction (say so in one line).
   State the working-tree gate either way: the `git diff` of what was applied, or
   which paths were dirty and therefore left untouched.
7. The **Warnings & assessment** table from §8 — the focus. For 🔧 fixable ones,
   propose the change as code/commands; **don't apply** — per repo policy all
   changes are GitOps/IaC and the user runs them.
8. **Skill feedback** — close every run with what this run taught the check itself:
   a false positive to accept-list, a manual command the sweep should have run, a
   miss a section should have caught, or a threshold that deserves a Prometheus rule.
   Propose it as a concrete edit to this file. "Nothing to change" is a valid answer;
   an empty section every run is not.

   **Repetition is itself a finding.** This file is the check's only memory, so
   anything worth knowing next run has to be written into it:

   - A warning assessed **✅ accept for the same reason more than twice** → promote it
     to a standing accepted condition (with a re-open trigger) or to the benign-lines
     list, so later runs stop re-deriving it.
   - A **🔧 fixable that keeps reappearing unfixed** → say how many runs it has
     survived and treat that as escalation, not as a fresh finding each time. Either
     it is harder than it looked (write down why) or it deserves an alert rule so it
     stops depending on someone running this check.
   - A standing condition whose **numbers drifted** past its baseline → re-open it,
     even if its alert is one already being accepted.
   - Something that fires **every single run and is always fine** → the threshold is
     wrong, not the cluster. Propose the corrected threshold, here or in
     `prometheus/values.yaml`.

If everything is green, say so plainly — don't invent work.
