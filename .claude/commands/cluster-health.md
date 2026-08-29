---
description: Health sweep of the k3s cluster (firing alerts, node metrics, pods, resource balance, ArgoCD, Longhorn, per-app logs, warnings) — read-only against infra; when the repo is clean it may apply resource sizing to values.yaml and its own skill-feedback edits to this file
argument-hint: "[log window, e.g. 1h, 6h — default 1h]"
allowed-tools: Bash(kubectl get:*), Bash(kubectl top:*), Bash(kubectl logs:*), Bash(kubectl describe:*), Bash(kubectl exec:*), Bash(ssh:*), Bash(git status:*), Bash(git diff:*), Bash(jq:*), Bash(grep:*), Bash(sed:*), Bash(awk:*), Bash(echo:*), Bash(printf:*), Bash(date:*), Bash(tail:*), Bash(head:*), Bash(cut:*), Bash(sort:*), Bash(uniq:*), Bash(comm:*), Bash(seq:*), Bash(wc:*), Bash(tr:*), Bash(for:*), Read, Edit
---

Run an on-demand health check of the homelab k3s cluster and give me a structured
report. Log scan window: `$1` (default `1h` if empty).

**The infrastructure is strictly read-only**: `kubectl get`/`top`/`logs`/`describe`/
`exec` of read commands, and read-only `ssh` OS inspection. No `apply`/`edit`/`patch`/
`scale`, no writes through any app's API, nothing changed on a node.

The one thing this check may write is the **repo working tree**, and only two things
in it, both behind §3's clean-tree gate:

- **resource requests and limits** in `values.yaml` (§3), and
- **this file** — the §8 skill-feedback edits, applied rather than merely proposed.

Both are proposing a change as code, which is how every change here is made; neither
touches the running cluster. Never `git add`/`commit`/`push`.

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
  rule for `prometheus/values.yaml`. Once the user applies one, replace the proposal
  here with a one-line reference — a rule that ships should not also live here as YAML.

Prometheus also answers questions this sweep otherwise guesses at — SMART drive
temperatures (`smartctl_device_temperature`), CPU throttling, memory peaks. Retention
is **15d**, so any "is this normal or new?" question is answerable, not speculative.

**Scrape health — the monitoring system's own blind spots.** An alert cannot fire on
a target Prometheus failed to scrape, so check the scrapers before trusting anything
below. Note `wget` chokes on `{` and `"` in a GET query string, so POST the query:

```
PQ() { kubectl exec -n monitoring deploy/prometheus-server -c prometheus-server -- \
  wget -qO- --post-data="query=$(printf %s "$1" | jq -sRr @uri)" 'localhost:9090/api/v1/query'; }
PQ 'avg_over_time(up[24h]) < 1' | jq -r '.data.result[]|"\(.metric.job)\t\(.metric.instance)\t\(.value[1])"'
```

🟡 any target below 1.0. A target that scrapes *slowly* fails the same way: a
`broken pipe` in an exporter's own log is Prometheus hanging up mid-response, and its
usual cause is that exporter's CPU limit (§3), not the network.

**Open monitoring gap** — nothing alerts on a failing scrape target, so a partially
blind Prometheus waits for someone to run this check. Proposed but not applied:
`PrometheusTargetScrapeFailing`, `avg_over_time(up[30m]) < 0.95` for 30m, warning.

## 1. Node metrics (structured, glanceable, comparable between runs)

`kubectl top nodes` gives CPU/mem from metrics-server, but pressure has more
angles. SSH each node read-only and gather load, CPU busy, iowait, block I/O,
memory, and per-mount disk usage. Discover the node list from `kubectl` rather than
naming them — node names are the SSH host names, and a hardcoded list goes stale the
day a node is added. `iostat`/`mpstat` are NOT installed — use `vmstat`/`free`/`/proc`
(they are):

```
for h in $(kubectl get nodes -o name | cut -d/ -f2); do echo "### $h"; ssh -o ConnectTimeout=5 "$h" \
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
for h in $(kubectl get nodes -o name | cut -d/ -f2); do echo "### $h"; ssh -o ConnectTimeout=5 "$h" \
  'echo "psi_cpu=$(awk "/some/{print \$3}" /proc/pressure/cpu) psi_io=$(awk "/some/{print \$3}" /proc/pressure/io) psi_mem=$(awk "/some/{print \$3}" /proc/pressure/memory)";
   echo "dstate_procs=$(ps -eo stat= | grep -c "^D")";
   grep " nfs " /proc/mounts | awk "{print \$2}" | grep -v kubelet'; done
```

- **PSI over load** — `/proc/pressure/*` `avg60` is the honest saturation signal.
  **k3s-server's load average lies**: it spikes to 10–20 with CPU idle, zero iowait
  and flat PSI (thread-churn artifact). On that node, judge by PSI and `CPU busy`,
  and never open a §8 warning on `Load÷core` alone. On node-02 the load is real.
- **`dstate_procs` > 0 with `/mnt/nas/media` present** — *possibly* the
  wedged-`hard`-NFS-mount failure mode. Uninterruptible processes survive `kill -9`;
  symptoms are node-wide slowness and high iowait, not one sick pod. The fix is at
  the NAS/mount end, not in k8s.

  **A single D-state process is not a wedge.** node-02 does continuous heavy DAS I/O,
  so a proc sitting in `D` for one sampling instant is ordinary disk wait and is the
  common case, not the failure. Resample before judging — only a D-state set that
  *persists* across samples is 🔴; one that clears is 🟢 and must not reach §8:

  ```
  ssh <node> 'ps -eo pid,stat,wchan:30,comm --no-headers | awk "\$2 ~ /^D/"; sleep 3;
    echo ---; ps -eo pid,stat,wchan:30,comm --no-headers | awk "\$2 ~ /^D/"'
  ```

  **The §1 `df` above is the wedge canary — read it, don't repeat it.** That first
  pass already touches every NFS mount, so a wedge shows up there as a `df` that
  hangs instead of returning. If it *did* return usage numbers for `/mnt/nas/media`,
  the mount is alive and the D-state is local I/O. Once a wedge is suspected, do
  **not** `ls`, `df` or `stat` the mount again to confirm — the re-probe hangs the
  check too; `/proc/mounts` and PSI are enough.

Flag with thresholds (these are warnings — carry to §8):
`Load÷core` 🟡 >1.0 / 🔴 >2.0 sustained (⚪ on k3s-server, see above) ·
`PSI io avg60` 🟡 >20 · `dstate_procs` 🔴 >0 *and persisting across a resample* ·
`CPU busy` 🟡 >85% · `iowait` 🟡 >20% ·
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
    "$(ssh $h 'test -e /var/run/reboot-required.pkgs && tr "\n" " " < /var/run/reboot-required.pkgs || echo none')"; done
  ```

  Hosts come from `kubectl`, as in §1. 🟡 once a node has been pending more than a
  week; 🔴 when the pending set includes `linux-image-*` **and** the booted kernel is
  behind the newest installed one (`ssh $h 'uname -r; ls -1 /boot/vmlinuz-*'`),
  because the security fix that prompted the update is not actually running. Report
  it as scheduled work with the quiesced-reboot command — never suggest rebooting the
  node in place.

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
- **Shared-uplink bounce** — a restart burst timestamped within one minute across
  *unrelated* namespaces, with `NodeNotReady` for most of the cluster, is the nodes
  losing the network, not apps failing. The nodes do not reboot, so uptime and the
  reboot marker read normal; `ssh <node> 'sudo dmesg -T | grep -i "link is"'` and UDB
  Homelab's uptime confirm it. It cuts every Longhorn replica mid-write, so check §5's
  `AutoSalvaged` events and confirm the volumes came back before closing it.

## 3. Resource right-sizing (requests/limits balance)

**First, the node view.** Per-container ratios say nothing about whether a node can
survive its own pods all peaking at once — the question that actually matters when
raising a limit:

```
for n in $(kubectl get nodes -o name | cut -d/ -f2); do echo -n "$n: "; \
  kubectl describe node "$n" | awk '/Allocated resources/,/Events/' | grep -E "^  (cpu|memory)" | tr '\n' ' '; echo; done
```

Report a **per-node allocation table** (`Status | Node | RAM | Requests | Limits % |
Verdict`). Requests are the scheduler's contract and must stay under 100%. Limits
routinely exceed 100% — that is normal overcommit — but the *ratio* is the blast
radius: node-02 runs deep in RAM overcommit, and a handful of containers peaking
together will OOM something. Read the live number from the command above and state it
before proposing any limit increase, and prefer raising a **request**
(scheduling truth) over a **limit** (ceiling) on a node already deep in overcommit.

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
  → **bump the mem request** toward real steady usage. Judge on the 7d **median**
  (`quantile_over_time(0.5, …)`), never the snapshot: a request sized for steady usage
  is meant to be exceeded during a burst, and `sabnzbd` after its drain window or
  `prometheus-server` mid-compaction both read as under-requested when they are not.
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

**`container_memory_working_set_bytes` over-reports for I/O-heavy containers.** The
working set counts active page cache, so anything streaming large files — `qbt-*`,
`sabnzbd`, `plex` — grows to fill whatever limit it is given without ever being at
risk: the kernel reclaims that cache under pressure instead of OOMing. Before calling
any container near-limit, cross-check RSS, which is the part that actually cannot be
reclaimed:

```
  'localhost:9090/api/v1/query?query=max_over_time(container_memory_rss{container="main",pod=~"<pod>.*"}[7d])/1024/1024'
```

A large working-set/RSS gap means page cache, not pressure — 🟢, and no limit change.
`qbt-se/main` is the standing example: its working set sits near its 8Gi limit while
RSS stays around 1.2Gi, so reading the working set alone produces a false 🔴 every run.

CPU pressure has an equivalent, and it beats `cpu %R` as evidence — throttling is the
symptom a CPU limit actually causes:

```
  'localhost:9090/api/v1/query?query=topk(10,rate(container_cpu_cfs_throttled_periods_total{container!=""}[6h])
     / rate(container_cpu_cfs_periods_total{container!=""}[6h]))'
```

Use the **ratio**, not the raw rate: throttled periods as a fraction of all periods is
comparable across containers, where a bare rate is not. Anything above ~15 % is real.

**A 7d peak cannot corroborate a CPU limit.** Bursty containers — exporters, gRPC
servers, anything doing per-scrape work — show a 5m-rate peak of 2–5m while throttling
20–60 % of periods, because the burst is far shorter than the sampling window. Sizing
those off the peak reads them as 60× over-provisioned when they are in fact starved.
For CPU the throttle ratio *is* the evidence; the 7d-peak requirement below applies to
**memory**, where the working set is a level rather than a spike.

Quote **snapshot _and_ 7d peak** in the table so the gap between them is visible (a
container idling at 200 Mi that peaked at 8 Gi is not over-provisioned), and name the
exact `values.yaml` and number. Sizing rule, split by resource because the evidence
differs:

- **Memory** — `request ≈ steady`, `limit ≈ 7d peak + headroom`.
- **CPU** — `request ≈ steady`; the **limit** comes from the throttle ratio, not from
  any peak. Raise it until throttling stops mattering; a CPU limit is a burst ceiling
  and overshooting it costs nothing, because CPU is compressible and unused ceiling is
  never reserved.

Carry 🔴 near-limit and 🟡 under-request rows into the §8 sweep as 🔧 fixable; keep
over-provisioning as a separate optimization note.

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
- **Only numbers corroborated by history**, never by the `kubectl top` snapshot alone
  — the 7d peak for memory, the throttle ratio for CPU. No history, no edit.
  **An `OOMKilled` is itself that history, and outranks the peak.** The kill is a
  sub-second spike, so a 30s-scrape working set never records it: expect the 7d peak
  to sit *well under* the limit on exactly the container that was killed, and raise
  the limit anyway. Never read a low peak as evidence the OOMKill was spurious.
- **No explanatory comments in the YAML.** Set the value and nothing else; the
  reasoning belongs in the report, where it is read once, not in the file, where it
  becomes stale verbosity. A sizing diff should be one changed line per number.
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
timestamped job pods only (`grep -E 'daily-backup-|weekly-backup-|monthly-backup-|snapshot-[0-9]'`)
— NOT the always-`Running` `csi-snapshotter` controller pods. All four schedules
produce pods; a regex covering only two silently reports on half the backup system.

**This job-pod check is the only coverage of a run that failed outright** — no alert
watches it. `kube_job_failed` only exists once a Job carries a `Failed` condition
(`backoffLimit: 3` exhausted), and `failedJobsHistoryLimit: 1` then keeps that Job
until the *next* failure evicts it, so a rule on it would fire permanently for a run
that has long since been superseded. A wholesale failure still reaches §0 as backup
age within ~6h; this check is what closes the gap in between.

**`robustness: healthy` does not mean the data is intact.** Longhorn reports on the
block device; it replicates a corrupted filesystem just as faithfully as a good one,
so a volume whose ext4 was destroyed by an unclean detach still shows
`attached`/`healthy` with every replica `Running`. The damage surfaces one layer up,
as a pod that never starts:

```
LIVE=$(kubectl get pods -A -o json | jq -c '[.items[]|.metadata.namespace+"/"+.metadata.name]')
kubectl get events -A --field-selector reason=FailedMount -o json \
| jq -r --arg t "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" --argjson live "$LIVE" '
  .items[] | select((.series.lastObservedTime // .lastTimestamp // .eventTime // .firstTimestamp) > $t)
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
job that still reports success, so check the **volumes**. Age is the detector; the
other two views explain a volume it has already flagged, and neither is a finding on
its own:

```
kubectl exec -n monitoring deploy/prometheus-server -c prometheus-server -- wget -qO- \
  'localhost:9090/api/v1/query?query=(time()-longhorn_volume_last_backup_at)/3600' \
  | jq -r '.data.result[]|"\(.metric.pvc_namespace)/\(.metric.pvc)\t\((.value[1]|tonumber)|floor)h"' | sort -k2 -rn
```

- **Age — the detector.** Against the schedule (`daily-backup` 01:00, `weekly-backup`
  Sun 02:00, `monthly-backup` 1st 03:00, all local; `snapshot-6h`).
  `longhorn_volume_last_backup_at` is the newest *completed* backup, so it is the only
  Longhorn backup signal that both ignores repaired failures and clears itself.
  `LonghornVolumeBackupStale` (warning) covers 30h–3d, `LonghornVolumeBackupMissing`
  (critical) takes over past 3d, so §0 normally catches this first.
- **Errors — why a volume is behind, not whether it is.** No alert is keyed on an
  `Error` CR, and one is not a finding on its own: the job retries a failed volume
  inside the same run, so most errors sit beside a successful backup of that volume
  minutes later — the data is safe and only the record remains. Longhorn keeps that
  record for `failed-backup-ttl` (1440m), so the list carries a full day of
  already-repaired failures. Read it once the age check has flagged a volume, and
  judge each error against that volume's `longhorn_volume_last_backup_at` — a newer
  success means recovered.

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

  `retrans=5` widened the budget but did not remove the ceiling — the largest volume
  still errors — so do not propose raising it again as a fix.
- **Gaps** — count *distinct volumes backed up per day* over the last week. A day
  whose count dips below its neighbours means specific volumes were skipped while the
  job still reported Completed, and the newest-backup timestamp stays green.

  **Bucket by local date, not UTC.** The jobs run 01:00 local and the cluster is
  `+0200`, so every nightly backup carries a `23:00Z` timestamp belonging to the
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

Also watch longhorn-manager (§6) for the backup-target reconcile failing to read the
NFS target. Two distinct messages, both retried forever:

- `Failed to get backupInfo from remote backup target` — a backup *record* that
  cannot be read; it names the volume it belongs to.
- `Failed to get info from backup store` … `timeout executing: … system-backup list`
  — the 5-minute target reconcile timing out against the NAS. Volume backups can all
  succeed while this fails, so check it against the volume evidence above before
  calling it a backup failure. A cluster of these inside a **single hour**, with no
  `Error`-state backups, is a transient NAS stall — accept it; recurrence across
  separate hours is not.

**Stuck volume expansion — `attached`/`healthy` hides it completely.** A PVC whose
size was raised in git can land half-expanded: Longhorn grows the block device, the
*engine* never finishes, and the filesystem inside stays at the old size. Every signal
§5 checks so far stays green — `state: attached`, `robustness: healthy`, backups
current — while `external-resizer` retries forever. Check the claim, not the volume:

```
kubectl get pvc -A -o json | jq -r '.items[]
  | select((.status.conditions//[])[]?.type=="Resizing" or (.spec.resources.requests.storage != .status.capacity.storage))
  | "\(.metadata.namespace)/\(.metadata.name)\twant=\(.spec.resources.requests.storage)\thave=\(.status.capacity.storage)"'
kubectl get volumes.longhorn.io -n longhorn-system -o json \
  | jq -r '.items[]|select(.status.expansionRequired)|"\(.metadata.name)\tspec=\(.spec.size)\texpansionRequired"'
```

Both queries only see an expansion that is **still in flight**. The moment it completes
— including when a reboot completes it as a side effect — they go clean and the incident
leaves no trace in any object's status. The `VolumeResizeFailed` event is the only
record that it happened at all, so read it too:

```
kubectl get events -A --field-selector reason=VolumeResizeFailed -o json | jq -r '.items[]
  | "\(.involvedObject.namespace)/\(.involvedObject.name)\t\(.count // .series.count)x\tfirst=\(.eventTime // .firstTimestamp)\tlast=\(.series.lastObservedTime // .lastTimestamp)"'
```

A hit whose `last` is inside the window but whose PVC now reads `spec == status` is a
**resolved** expansion — report it as such, not as a live 🔴, and say what completed it.
A rack reboot resolves one incidentally, by detaching the volume.

🔴 on any hit of the two live queries. Confirm by comparing the engine's `spec.volumeSize` against its
`status.currentSize` (equal = done; different with `EngineMonitor` logging
`Starting engine expansion` on a loop = stuck), and read the real filesystem size with
`kubectl exec -n <ns> deploy/<app> -- df -h <mountpath>`.

Online expansion is what fails; the engine completes it once the volume is **detached**.
So the fix is a quiesce cycle — but two details decide whether it works, and getting
either wrong looks like the fix simply doing nothing:

- **Suspend the root App-of-Apps *first*.** `media-apps` reverts `syncPolicy` patches
  on its children, so suspending only the per-service app lets the child be re-enabled
  and the Deployment scaled straight back to 1 — the pod returns within seconds.
  See `docs/pvc-maintenance.md` → "Two-tier ArgoCD app structure".
- **Wait on the Longhorn volume reaching `state: detached`, not on the pod being
  deleted.** Pod deletion is not detachment; a pod that comes back before the volume
  detaches leaves the engine on the same stale instance-manager and nothing changes.

Re-enable in reverse: per-service app first, root **last**. Never `kubectl patch` the
PVC or edit the Longhorn volume to paper over it.

**Open monitoring gap** — a stuck expansion is silent between runs of this check.
Proposed but not applied: `LonghornVolumeExpansionStuck`, comparing
`longhorn_volume_capacity_bytes` against `longhorn_volume_actual_size_bytes` on an
attached volume for 30m; verify the metric names against `/api/v1/label/__name__/values`
first. The `kubectl get pvc` query above is the authoritative check for an expansion
still in flight, and the `VolumeResizeFailed` event for one that has since resolved.

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
Q='sum by (namespace, app) (count_over_time({namespace=~".+"} |~ "(?i)(error|fatal|panic|warn)" != "\"error\":null" != "error=null" ['"$W"']))'
kubectl exec -n monitoring deploy/grafana -c grafana -- wget -qO- http://loki:3100/loki/api/v1/query \
  --post-data="query=$(printf %s "$Q" | jq -sRr @uri)" \
  | jq -r '.data.result[]|"\(.value[1])\t\(.metric.namespace)/\(.metric.app)"' | sort -rn
```

The two `!=` filters mirror Pass 2's exclusions. Without them the count is inflated by
structured-log lines whose *success* payload contains the word — `"error":null` — and
an app is ranked near the top of the sweep with nothing wrong with it, then drills down
to zero lines. Any exclusion added to Pass 2 belongs here too, or the ranking lies.

**Establish currency before triaging.** A count is a total over the window and says
nothing about *when*. After a node reboot — or any restart — the drill-down fills with
startup churn that was over in seconds, and it looks identical to a fault that has been
running all day. Re-run the app's dominant message over a short trailing window; if the
recent count is zero, it is history:

```
kubectl logs -n "$ns" "$pod" --all-containers --since=20m 2>/dev/null | grep -c '<message>'
kubectl logs -n "$ns" "$pod" --all-containers --since="$W" --timestamps 2>/dev/null \
  | grep '<message>' | sed -n '1p;$p' | cut -c1-30   # first and last occurrence
```

Pass a real pod name, never a `-l` selector: `kubectl logs -l` prints nothing and exits
0 when nothing matches, so a guessed label yields a count of `0` that is
indistinguishable from a burst that ended. Loki's labels are not the pods'
(`app=longhorn` in Loki is `app=longhorn-manager` on the pod) — when unsure, bucket
Pass 1's query by `[1h]` instead, which answers *when* without needing a selector.

Do this for every burst before writing it into §8 — the §8 Frequency column should read
"3 311, all inside the reboot minute" or "60/h, ongoing", never a bare total.

**Every app with a non-zero count gets triaged — including the ones whose count looks
"normal".** A steady 60/h of the same benign line is still noise worth fixing at the
source (log level, probe interval, a stale config the app is complaining about). The
goal is a **quiet** log, not merely a fault-free one: noise is what hides the one line
that matters. Work down the list by count.

**Pass 2 — the drill-down.** For each app that surfaced, read the actual lines,
ranked by repetition.

The workstation shell is **zsh**, which does not word-split unquoted parameters.
Iterate `ns pod` pairs with `printf '%s\n' … | while read -r ns pfx`, never
`for t in "ns app"; do set -- $t`, which yields an empty `$2` and fails silently —
producing empty drill-down sections that look like clean apps.

```
kubectl logs -n "$ns" "$pod" --all-containers --prefix --since="$1" 2>/dev/null \
  | sed 's/\x1b\[[0-9;]*m//g' \
  | grep -iE '\b(error|fatal|panic|warn(ing)?)\b|level=(error|warn)|"level":"(error|warn|fatal)"|[[:space:]]E[0-9]{4}[[:space:]]|\[(error|crit)\]' \
  | grep -ivE '"error":null|error=null|level=info|caller=metrics\.go|warnings\.go|is deprecated|"GET |"POST |HTTP/[12]' \
  | sed -E 's/[0-9]{4}-[0-9-]*T?[0-9:.]*Z?//g; s/\b[EWIF][0-9]{4} [0-9:.]+ +[0-9]+\b//g; s/[0-9]{2}:[0-9]{2}:[0-9]{2}//g; s/[0-9]+/N/g' \
  | sort | uniq -c | sort -rn | head -10
```

`uniq -c` ranks distinct messages by how often they repeat. **All four `sed`
substitutions are load-bearing**: ISO stamps, klog (`W0827 11:31:11.275065       1`),
bare `HH:MM:SS`, and the blanket `[0-9]+`→`N` for IPs, ports, durations and IDs. Any
format left un-normalized makes every line unique and `uniq -c` returns a column of
`1`s. It costs some readability, which is the right trade for a ranking pass — read the
raw lines for the one message that matters. A message seen once and one seen 4 000
times need different responses, so the count must survive into §8.

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
`FailedScheduling` from the last rack maintenance both read as current problems.

**For a repeating event, `eventTime` is the *first* observation, not the last** — the
last lives in `.series.lastObservedTime`. Filtering on `eventTime` therefore fails in
both directions: it collapses a long-running burst to a single line at the wrong
instant, and it drops an event that is *still firing* whenever the series began before
the window. Order the coalesce last-first, and read the span, not a point: a large
`count` between a first and last that differ by hours is one past incident, while the
same count whose last observation is minutes old is live.

```
kubectl get events -A --field-selector type=Warning -o json | jq -r --arg t "$(date -u -d '12 hours ago' +%Y-%m-%dT%H:%M:%SZ)" '
  .items[] | (.series.lastObservedTime // .lastTimestamp // .eventTime // .firstTimestamp) as $last
  | (.eventTime // .firstTimestamp // $last) as $first
  | select($last != null and $last > $t)
  | "\($last)\t\(.reason)\t\(.involvedObject.namespace)/\(.involvedObject.name)\t\(.count // .series.count // 1)x\tsince=\($first)\t\(.message[0:100])"' | sort
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
- loki query-stats (`caller=metrics.go`, `level=info`) and coredns `[INFO]`/`[WARNING]`
  query logs — verbose telemetry, not faults. coredns query logging is deliberately on
  and dominates every Loki count by tens of thousands per hour; rank it, then set it aside.
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
- **Startup churn in the minute after a node restart** — every rack cycle reproduces
  the same set, in volume: cert-manager `ACME client for issuer not initialised`,
  longhorn-manager `mismatching disks`, the CSI sidecars' `dial unix /csi/csi.sock:
  connect: connection refused`, promtail readiness-probe timeouts, and qui `instance is
  in backoff period` — each a controller reconciling ahead of its dependency. All
  self-clear. **Accepted only when confined to the restart window**: establish that with
  §6's currency check, and confirm the end state with `kubectl get clusterissuer` +
  `kubectl get certificates -A` (all `Ready=True`) and `kubectl get nodes.longhorn.io
  -n longhorn-system` (every disk `Ready`/`Schedulable`). The same message still
  arriving 20 minutes later is a real finding.
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

Baseline for that row (so drift is detectable rather than a fresh surprise), as of
**2026-08-29**: steady **52/53 °C** (sda/sdb), 7d max **54/56 °C**, SMART otherwise
clean — and `DiskTemperatureHigh` **not firing**, the enclosure having settled below
its 58 °C threshold. (Previous baseline, 2026-08-28: steady 52/54 °C, 7d max 55/56 °C.)
Quote the current numbers against that baseline in the one-liner — an accepted
condition still gets measured.

The row stays despite the quiet alert: the drives still run 13–15 °C above Toshiba's
40 °C recommendation, and the margin comes from ambient cooling, not a fix. **Retire it
only after a full warm-week holds under 58 °C.** `DiskTemperatureHigh` fires on a 1 h
average above **58 °C** — deliberately the same number as this row's re-open trigger, so
the alert and the acceptance say one thing; retiring the row orphans that rationale.

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
   propose the change as code/commands and **don't apply it to the cluster** — per
   repo policy all changes are GitOps/IaC and the user runs them. The two exceptions
   are the repo-only writes named in the preamble: §3's `resources:` numbers and this
   file's own §8 edits, both behind the clean-tree gate.
8. **Skill feedback** — close every run with what this run taught the check itself:
   a false positive to accept-list, a manual command the sweep should have run, a
   miss a section should have caught, or a threshold that deserves a Prometheus rule.
   "Nothing to change" is a valid answer; an empty section every run is not.

   **Most findings do not belong in this file.** A run surfaces plenty that is worth
   saying and not worth persisting: what a metric read today, which incident a burst
   traced back to, why a number was chosen, what got ruled out. That belongs in the
   report, discussed in the session. Only write here what **changes how a future run
   behaves** — a check it would otherwise not run, a false positive it would otherwise
   re-derive, a threshold, a failure mode with a named fix, a command that was wrong.
   Everything else is bloat that makes the rest less trustworthy. Specifically, keep out:

   - **This run's measurements.** Dates and readings age into lies. The exception is a
     standing condition's baseline, which exists to be compared against.
   - **Narrated history** — "X did not work", "this used to be Y", "verified the hard
     way". State what *is*, and what to do. If a ruled-out fix would otherwise be
     re-proposed, one clause saying so is the whole entry.
   - **Illustrative examples**, unless the example is the recurring false positive
     itself and naming it saves the next run the investigation.
   - **Decisions still being weighed.** Bring those to the user in the report. Once
     decided, what lands here is the resulting rule or check, not the deliberation.

   **Apply the edit under the same gate as §3's sizing.** Clean tree at the start of
   the run → edit this file directly and show the `git diff`. Dirty → propose the diff
   and change nothing. The same narrow rules apply: only this file, never `git
   add`/`commit`/`push`, and the user reviews. A finding that stays a proposal is one
   the next run re-derives from scratch.

   **Then sweep this whole file before finishing — every run, not just the ones that
   changed it.** This file grows by accretion: each run bolts on a finding, and
   nothing removes anything. Left alone it drifts into a document that contradicts
   itself and is too long to trust. Read it end to end and fix:

   - **Contradiction** — two passages that cannot both be followed. The newest one is
     usually right and the older one usually needs *scoping*, not deletion (a rule
     that held universally may now hold only for memory, or only for cluster state).
   - **Duplication** — the same guidance stated in two sections. Keep it where it is
     acted on and leave a cross-reference at the other, never a second copy that will
     drift.
   - **Staleness** — a literal that reality has moved past: a grep string the logs no
     longer emit, a regex that misses a job that now exists, a hardcoded percentage,
     a path or filename that was renamed. Every literal in this file is a claim about
     the cluster; verify the ones this run touched and correct what has drifted.
   - **Hardcoded lists** — node names, namespaces, apps, volumes enumerated by hand.
     Replace with the discovery query. This file tells its own §2 to do this; the
     rule applies to the file itself.
   - **Expired notes** — anything carrying a date or a re-evaluate-by. Act on it when
     due, and *delete* it once acted on. A dated note left past its date is worse
     than no note: it reads as current.
   - **Bloat** — anything failing the test above: a measurement, a narrated incident,
     an example carrying no rule, a proposal already applied or already declined. Cut
     it and keep whatever rule it was carrying.
   - **Ambiguity** — a threshold with no unit, a verdict with no owning section, an
     instruction whose subject is unclear on a cold read.

   Report what the sweep changed, and say **"swept, nothing to tidy"** when it found
   nothing — silence is indistinguishable from not looking.

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
