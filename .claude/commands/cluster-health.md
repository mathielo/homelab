---
description: Health sweep of the k3s cluster (firing alerts, node metrics, pods, resource balance, ArgoCD, Longhorn, per-app logs, warnings) — read-only against infra; when the repo is clean it may apply resource sizing to values.yaml and its own skill-feedback edits to this file
argument-hint: "[log window, e.g. 1h, 6h — default 1h]"
allowed-tools: Bash(kubectl get:*), Bash(kubectl top:*), Bash(kubectl logs:*), Bash(kubectl describe:*), Bash(kubectl exec:*), Bash(ssh:*), Bash(git status:*), Bash(git diff:*), Bash(jq:*), Bash(grep:*), Bash(sed:*), Bash(awk:*), Bash(echo:*), Bash(printf:*), Bash(date:*), Bash(tail:*), Bash(head:*), Bash(cut:*), Bash(sort:*), Bash(uniq:*), Bash(comm:*), Bash(seq:*), Bash(wc:*), Bash(tr:*), Bash(for:*), Read, Edit
---

Run an on-demand health check of the homelab k3s cluster and report in the **Output**
format. Log scan window: `$0` (default `1h` if empty), written `W` below.

**The infrastructure is strictly read-only**: `kubectl get`/`top`/`logs`/`describe`/
`exec` of read commands, and read-only `ssh` OS inspection. No `apply`/`edit`/`patch`/
`scale`, no writes through any app's API, nothing changed on a node.

The only thing this check may write is the **repo working tree**, and only two things in
it, both behind §3's clean-tree gate: **`resources:` requests/limits** in `values.yaml`
(§3) and **this file** (skill feedback). Never `git add`/`commit`/`push`.

Batch independent commands in parallel, then **interpret** the results — don't dump raw
output. Separate real problems from known-benign noise. Hunt warnings thoroughly and
decide for each whether it's fixable or accepted (§8), but the report shows a status table and
only the findings that need action (**Output**); thoroughness is in the investigation.

## 0. Firing alerts (start here)

The alert rules in `k3s/apps/monitoring/prometheus/values.yaml` (node/disk/PVC, Longhorn,
SMART, ingress, cert expiry, Pi-hole HA) are the authoritative statement of what
"unhealthy" means here — read it before hand-rolling any threshold below. Retention is
**15d**, so "normal or new?" is answerable rather than speculative.

Two helpers, used by every section below. `wget` chokes on `{` and `"` in a GET query
string, so always POST:

```
PQ()  { kubectl exec -n monitoring deploy/prometheus-server -c prometheus-server -- wget -qO- \
        --post-data="query=$(printf %s "${1}" | jq -sRr @uri)" localhost:9090/api/v1/query; }
PQR() { kubectl exec -n monitoring deploy/prometheus-server -c prometheus-server -- wget -qO- \
        --post-data="query=$(printf %s "${1}" | jq -sRr @uri)&start=$(date -d "${2:-7 days ago}" +%s)&end=$(date +%s)&step=${3:-3600}" \
        localhost:9090/api/v1/query_range; }
L='\(.metric.pvc // .metric.persistentvolumeclaim // .metric.device // .metric.pod // .metric.deployment // .metric.daemonset // .metric.statefulset // .metric.node // "-")'
```

`node` is the last resort in `L`: on kube-state-metrics alerts it names the node the KSM pod
runs on, not the target, so a `DeploymentNotAvailable` would read as a node.

**Firing now** — every one is assessed in §8; a report that says 🟢 while an
*unassessed* alert is firing is wrong. `pending` ones are leads to investigate.

```
PQ 'ALERTS' | jq -r ".data.result[]|\"\(.metric.alertstate)\t\(.metric.severity)\t\(.metric.alertname)\t$L\"" | sort -u
```

**Fired since the last run** — the instant vector shows only this second, and the
interesting failures self-resolve between runs: a volume that missed two nights of
backups, or a disk that crossed its temperature threshold for two hours, reads as clean
by the time anyone looks. `ALERTS` is a recorded series, so its history answers what the
instant query cannot:

```
PQR 'max_over_time(ALERTS{alertstate="firing"}[1h])' | jq -r ".data.result[]|\"\(.metric.alertname)\t\(.metric.severity)\t$L\tfirst=\(.values[0][0]|tonumber|strftime(\"%m-%d %H:%M\"))\tlast=\(.values[-1][0]|tonumber|strftime(\"%m-%d %H:%M\"))\t\(.values|length)h\"" | sort
```

The `[1h]` window is load-bearing: a bare `ALERTS` range query samples one instant per
hourly step, so an alert that fires and clears between two samples — a node reboot's
`DeploymentNotAvailable`, a 10-minute `DiskTemperatureCritical` — never appears.
`.values|length` then counts hours with any firing sample.

An alert that fired and cleared is history, not a current fault, but it is the evidence
§1–§7 are mostly blind to, and it is what evaluates a standing condition's re-open trigger.
Trace each one to its end state: it becomes an Output item only if it left something
degraded (a backup still missing, a volume still rebuilding) or keeps recurring with
damage. A blip that cleared clean is dropped.

An alert in §8's **standing accepted conditions** is already assessed: it shows only as a ⚪
summary row. Do still evaluate its **re-open trigger**.

This section also keeps the skill honest, both ways:

- **A firing alert no §1–§7 check would have caught** = a blind spot here. Name it,
  propose the check.
- **A threshold here with no matching alert rule** = a monitoring gap; this check runs
  when the user runs it, a rule runs always. Propose it for `prometheus/values.yaml`, and
  once applied replace the proposal with a one-line reference — a rule that ships should
  not also live here as YAML.

**Scrape health** — an alert cannot fire on a target Prometheus failed to scrape:

```
PQ 'avg_over_time(up[24h]) < 0.99' | jq -r '.data.result[]|"\(.metric.job)\t\(.metric.instance)\t\(.value[1])"'
```

🟡 any hit. The bound is **0.99**, not `< 1.0`: one missed scrape in 24h happens on every
run and means nothing. A target that scrapes *slowly* fails the same way — a `broken pipe`
in an exporter's own log is Prometheus hanging up mid-response, usually that exporter's
CPU limit (§3), not the network.

After node reboots inside the 24h, every target on those nodes dips below the bound, and
pod IPs that no longer exist stay listed. Re-run it over `up[15m]`: clean there means the
hits are the reboot, not a flapping target.

**Open monitoring gap** — `PrometheusTargetDown` (`up == 0` for 10m) covers a target that
stays down, so only a *flapping* one is blind. Proposed, not applied:
`PrometheusTargetScrapeFailing`, `avg_over_time(up[30m]) < 0.95` for 30m, warning.

## 1. Node OS metrics

One read-only SSH pass per node collects everything the OS knows — load, CPU, PSI,
D-state, NFS mounts, the pending-reboot marker, per-mount usage. **Keep it to this one
pass**: extra round-trips cost every run and buy nothing, and on a node with a wedged NFS
mount a second probe is actively harmful (below). Discover nodes from `kubectl` — node
names are the SSH host names, and a hardcoded list goes stale the day one is added.
`iostat`/`mpstat` are NOT installed; `vmstat`/`free`/`/proc` are:

```
for h in $(kubectl get nodes -o name | cut -d/ -f2); do echo "### $h"; ssh -o ConnectTimeout=5 "$h" \
  'cores=$(nproc); load=$(cut -d" " -f1-3 /proc/loadavg); v=$(vmstat 1 2 | tail -1);
   usr=$(echo $v|awk "{print \$(13)}"); sys=$(echo $v|awk "{print \$(14)}"); wa=$(echo $v|awk "{print \$(16)}");
   bi=$(echo $v|awk "{print \$(9)}"); bo=$(echo $v|awk "{print \$(10)}");
   mem=$(free -m|awk "/^Mem:/{printf \"%d/%dMi (%d%%)\",\$(3),\$(2),\$(3)*100/\$(2)}");
   echo "cores=$cores load=[$load] cpu_busy=$((usr+sys))% iowait=${wa}% blk_in=${bi} blk_out=${bo} mem=$mem";
   echo "psi_cpu=$(awk "/some/{print \$(3)}" /proc/pressure/cpu) psi_io=$(awk "/some/{print \$(3)}" /proc/pressure/io) psi_mem=$(awk "/some/{print \$(3)}" /proc/pressure/memory)";
   echo "dstate=$(ps -eo stat= | grep -c "^D") up=$(awk "{print int(\$(1)/86400)}" /proc/uptime)d";
   echo "aa_signal_denied_1h=$(journalctl -k -q --since -1h --grep "apparmor=\"DENIED\" operation=\"signal\"" | wc -l)";
   grep " nfs " /proc/mounts | awk "{print \$(2)}" | grep -v kubelet;
   echo "failed_units=$(systemctl --failed --no-legend --plain | awk "{print \$(1)}" | tr "\n" " ")";
   test -e /var/run/reboot-required.pkgs && echo "reboot_pending=$(tr "\n" " " < /var/run/reboot-required.pkgs)" || echo "reboot_pending=none";
   df -h -x tmpfs -x devtmpfs -x overlay -x efivarfs --output=target,size,used,pcent | tail -n +2 | grep -vE "/boot/efi"'; echo; done
```

Tabulate these for the assessment (they roll up into the Nodes and Disk space summary
rows), each row's **Status** (🟢 ok / 🟡 warning / 🔴 critical / ⚪ by-design) = its
worst breached metric:

- **Compute**, one row per node: `Status | Cores | Load 1/5/15 | Load÷core | CPU busy% | iowait% | Blk I/O in/out | Mem`.
  `Load÷core` (load15 ÷ cores) is the real saturation signal, not raw load.
- **Disk**, one row per mount returned: `Status | Mount | Size | Used | Use%`. Mounts vary
  per node (`docs/hardware.md`) — report what `df` returned, don't expect a fixed set.

Thresholds **mirror the alert rules** deliberately, so the check and the always-on rule
say one thing. Change one, change both:

| Metric                | 🟡        | 🔴                                | Alert rule                              |
| --------------------- | --------- | --------------------------------- | --------------------------------------- |
| `Load÷core`           | >1.0      | >2.0                              | — (none; see k3s-server caveat)         |
| `CPU busy`            | >85%      | —                                 | `NodeHighCPU` (>85%, 15m)               |
| `Mem`                 | >85%      | —                                 | `NodeHighMemory` (>85%, 5m)             |
| `iowait`              | >20%      | —                                 | —                                       |
| `PSI io`              | avg60 >20 | —                                 | —                                       |
| `dstate_procs`        | —         | >0 *persisting across a resample* | —                                       |
| Disk use              | ≥85%      | ≥90%                              | `NodeDiskPressure` / `NodeDiskCritical` |
| `aa_signal_denied_1h` | >0        | —                                 | —                                       |
| `failed_units`        | —         | any                               | —                                       |

- **`/mnt/r0` (k3s-node-02) is always ⚪** — never 🟡/🔴, never reported. It is a bulk
  media array whose working state is full; the disk rules exclude it by
  `mountpoint!="/mnt/r0"` for the same reason.
- **PSI over load** — `/proc/pressure/*` `avg60` is the honest saturation signal.
  **k3s-server's load average lies**: it spikes to 10–20 with CPU idle, zero iowait and
  flat PSI (thread-churn artifact). There, judge by PSI and `CPU busy`, and never open a
  §8 warning on `Load÷core` alone. On node-02 the load is real.
- **`/` trends high** on every node (containerd image cache in `/var/lib/k3s/agent`). Note
  ≥85%, but kubelet image-GC self-prunes at 85%/80% (`ansible/k3s/install-k3s.yaml`), so
  high-but-stable is not a finding; `NodeRootDiskFillingUp` catches a real trend.

- **`aa_signal_denied_1h` > 0** — containers are carrying the stacked AppArmor label and
  can't signal their own processes (`99-apparmor-containers.conf` in
  `ansible/k3s/install-k3s.yaml` missing or not yet applied to running pods). Name the
  senders with `journalctl -k --since -1h --grep 'operation="signal"'`; comms with spaces,
  like .NET's thread names, are hex-encoded in the audit record.

- **`failed_units`** — read the reason with `systemctl status <unit>` on that node. A
  failed oneshot like `nfs-server` doesn't come back by itself and nothing alerts on it;
  on k3s-node-02 it means the workstation's `/mnt/n02r0` automount times out.

**Wedged `hard` NFS mount** — `dstate_procs` > 0 with `/mnt/nas/media` present is
*possibly* this. Uninterruptible processes survive `kill -9`; symptoms are node-wide
slowness and high iowait, not one sick pod, and the fix is at the NAS/mount end, not in
k8s. Two rules before calling it:

- **The `df` above is the canary.** If it returned usage for `/mnt/nas/media` the mount is
  alive and the D-state is local I/O. Once a wedge *is* suspected do **not** `ls`, `df` or
  `stat` the mount to confirm — the re-probe hangs the check too; `/proc/mounts` and PSI
  are enough.
- **A single D-state process is not a wedge.** node-02 does continuous heavy DAS I/O, so a
  proc in `D` for one instant is ordinary disk wait — the common case. Only a set that
  *persists* across a resample is 🔴:

  ```
  ssh <node> 'ps -eo pid,stat,wchan:30,comm --no-headers | awk "\$(2) ~ /^D/"; sleep 3;
    echo ---; ps -eo pid,stat,wchan:30,comm --no-headers | awk "\$(2) ~ /^D/"'
  ```

**Pending kernel reboot** — the nodes install security updates unattended but never reboot
themselves, because an unattended reboot tears Longhorn volumes off mid-write (§5); the
reboot is deferred to `make shutdown` / `make startup`. Nothing in `kubectl` shows it and
no alert covers it, so the marker file in the pass above is its only coverage.

A pending kernel is **routine maintenance, not a fault** — never 🔴. Ubuntu ships a new
kernel roughly every two weeks, so a node is almost always one behind; the nodes sit on the isolated Servers VLAN with nothing publicly
exposed, so the fixes are mostly local privilege escalation, reachable only from code
already running on the node. The cost of waiting grows slowly; a `make shutdown` /
`make startup` cycle is real work. Judge by **uptime**, not by the marker's age — every new
kernel appends to the marker, so its mtime resets every two weeks and never looks old:

- ⚪ kernel pending, `up` < 60d — not reported; it rides the next planned rack
  maintenance.
- 🟡 kernel pending, `up` ≥ 60d — about four kernel releases of fixes not running; propose
  scheduling the cycle.

Report it as scheduled work with the quiesced-reboot command; never suggest rebooting a
node in place.

## 2. Node conditions & pods

- `kubectl get nodes -o wide`; flag any `*Pressure=True` or not `Ready`.
- `kubectl get pods -A`; flag anything not `Running`/`Completed` (CrashLoopBackOff,
  Pending, Error, OOMKilled, ImagePullBackOff).
- **Restarts:** containers with `lastState.terminated.finishedAt` in the last ~24h
  (`kubectl get pods -A -o json | jq`). Old restart counts all tracing to one past
  timestamp = a prior planned reboot, **not** churn — say so rather than alarming. Note
  the `reason`: an **OOMKilled** terminated-state feeds §3.
- **Pods much younger than their node** mean something deployed recently. A fresh
  ReplicaSet hash plus a fresh image pull across `cert-manager`/`argocd`/`monitoring` is
  an **Ansible or Helm run in flight**, not a fault — and every app it touched will show
  startup churn in §6. Establish this *before* triaging logs, or the run reads as a
  cluster-wide incident:
  `kubectl get pods -A --sort-by=.metadata.creationTimestamp | tail -20`.

**Silent failures** — `Running` with `0 restarts` is not proof of health. Three modes here
present as a perfectly green pod (a wedged NFS mount is a fourth, caught in §1):

- ***arr s6 self-restart bind loop*** — the in-app Restart button orphans the process and
  s6 respawns a doomed instance every ~4.5 s **forever**. Pod stays `1/1 Running`,
  restarts `0`, `/ping` returns 200; only ~0.7 cores of CPU and a flood of identical log
  lines give it away. Any *arr at high steady CPU with a repeating startup line in §6 is
  this. Fix: `kubectl rollout restart` (never the UI Restart button).
- **gluetun port-forward drop** (`qbt-*`) — ProtonVPN forwarded ports **never auto-recover**
  once dropped, and the container reports healthy throughout. Compare gluetun's forwarded
  port against what qBittorrent is listening on:

  ```
  for q in qbt-se qbt-br qbt-mam; do echo -n "$q "; \
    kubectl exec -n media deploy/$q -c gluetun -- cat /tmp/gluetun/forwarded_port; \
    kubectl exec -n media deploy/$q -c main -- wget -qO- localhost:8080/api/v2/app/preferences | jq .listen_port; done
  ```

  Read the **file**, not the control API: gluetun ≥3.40 requires auth on `:8000`, so
  `wget localhost:8000/v1/...` exits 6 rather than answering. A mismatch is 🟡 fixable
  (`vpn-port-healer` handles rotation — confirm it acted). `gluetun`, `vpn-port-healer`
  and `cleanup-stale-lock` are **native sidecars** (initContainers with
  `restartPolicy: Always`): `kubectl exec -c <name>` reaches them, anything reading
  `.spec.containers[]` does not (§3).
- **Shared-uplink bounce** — every node losing link at the same second is the shared
  switch port dropping, not apps failing. They don't reboot, so uptime and the reboot marker
  read normal. A bounce shorter than the node-monitor grace period leaves no `NodeNotReady`
  and often no restart burst, so detect it from carrier counts, not from symptoms:

  ```
  PQ 'increase(node_network_carrier_changes_total{device=~"en.*|eth.*"}[3d])' \
    | jq -r '.data.result[]|"\(.metric.instance)\t\(.metric.device)\t\(.value[1]|tonumber|floor)"'
  ```

  (substitute the run's window for `3d`.) Equal non-zero counts across hosts = a shared
  bounce; place each episode with `ssh <node> 'sudo journalctl -k --since -14d | grep -i
  "link is down"'`. It cuts Longhorn replicas mid-write — longhorn-manager relays the engine's
  `Error reading from wire` as a burst of `printInstanceLogs` warnings — so check §5's
  `AutoSalvaged` events and confirm the volumes came back. Bounces happen occasionally and
  are dropped from the report when everything came back; only lasting damage (a volume
  still degraded, a pod not ready, a port-forward lost) is an item.

## 3. Resource right-sizing (requests/limits balance)

**First, the node view** — per-container ratios say nothing about whether a node survives
its own pods all peaking at once, which is the question when raising a limit:

```
for n in $(kubectl get nodes -o name | cut -d/ -f2); do echo -n "$n: "; \
  kubectl describe node "$n" | awk '/Allocated resources/,/Events/' | grep -E "^  (cpu|memory)" | tr '\n' ' '; echo; done
```

Read the **per-node allocation** (requests and limits as % of RAM). Requests are the scheduler's contract and must stay under 100%. Limits
routinely exceed 100% — normal overcommit — but the *ratio* is the blast radius: node-02
runs deep in RAM overcommit, and a handful of containers peaking together will OOM
something. Read the live number before proposing any limit increase, and on a node already
deep in overcommit prefer raising a **request** (scheduling truth) over a **limit**.

Then the per-container view, joining live usage against configured values on the
`ns/pod/container` key:

```
awk -F'\t' 'NR==FNR{r[$(1)]=$(2)" "$(3)" "$(4)" "$(5); next} ($(1) in r){print $(1)"\t"$(2)"\t"$(3)"\t"r[$(1)]}' \
  <(kubectl get pods -A -o json 2>/dev/null | jq -r '.items[]|.metadata.namespace as $ns|.metadata.name as $p|(.spec.containers[], .spec.initContainers[]?)|[$ns+"/"+$p+"/"+.name,(.resources.requests.cpu//"-"),(.resources.limits.cpu//"-"),(.resources.requests.memory//"-"),(.resources.limits.memory//"-")]|@tsv' | sort) \
  <(kubectl top pods -A --containers --no-headers 2>/dev/null | awk '{print $(1)"/"$(2)"/"$(3)"\t"$(4)"\t"$(5)}' | sort)
```
(columns: `key  cpu_use  mem_use  cpu_req cpu_lim mem_req mem_lim`)

`(.spec.containers[], .spec.initContainers[]?)` is required because `.spec.containers[]`
alone drops every native sidecar — and `kubectl top --containers` omits them anyway, so
the join will not list them. Their usage is visible only through the Prometheus queries
below; check sidecar throttling there.

Pick out the containers worth attention (not all ~60):

- 🔴 **Memory near limit** — `mem %L ≥ 90%`, or any **OOMKilled** history (§2, and
  `PodOOMKilled` in §0) → **raise the mem limit**. OOMKilled is definitive; a high
  snapshot alone is only a lead. A `NodeOOMKill` in §0's history with no `PodOOMKilled`
  beside it is a child process or host process killed with no restart to show for it:
  `ssh <node> 'sudo journalctl _TRANSPORT=kernel --since -1d --grep "Killed process"'`
  names it (`-k` would read only the current boot).
- 🟡 **Under-requested memory** — `mem %R > 100%`: the scheduler under-counts it and it is
  first evicted under node pressure → **bump the mem request** toward steady usage. Judge
  on the 7d **median** (`quantile_over_time(0.5, …)`), never the snapshot — a request
  sized for steady usage is *meant* to be exceeded during a burst, and `sabnzbd` after its
  drain window or `prometheus-server` mid-compaction both read as under-requested when
  they are not.
- 🟡 **Under-requested CPU** — `cpu %R` persistently ≫ 100% on a latency-sensitive service
  (not a batch/burst job) → nudge the CPU request up.
- 🟡 **Over-provisioned (waste)** — `mem %R < 20%` **and** `cpu %R < 10%` on a steady
  service: it hoards schedulable capacity (esp. CPU — a 500m request idling at 5m). An
  optimization, not a fault — not an Output item.
- ⚪ **No requests/limits set** — note a missing mem request (unbounded scheduling) or mem
  limit (can starve neighbours); tiny sidecars may be intentionally unset — judge.

**Do NOT flag as over-provisioned** workloads whose high ceilings are deliberate burst
headroom: `qbt-*` main + `gluetun` sidecars, `plex`, `sabnzbd`, and anything whose
values.yaml comment marks the size as intentional. Over-provisioning flags target steady
low-usage services (arr apps, small web UIs) with fat requests.

### Sizing evidence

**Never size off the snapshot** — `kubectl top` is one instant. The evidence differs per
resource.

**Memory**: `request ≈ steady`, `limit ≈ 7d peak + headroom`.

```
PQ 'topk(20,max_over_time(container_memory_working_set_bytes{container!=""}[7d])/1024/1024)' \
  | jq -r '.data.result[]|"\(.metric.namespace)/\(.metric.pod)/\(.metric.container)\t\(.value[1]|tonumber|floor)Mi"'
```

`container_memory_working_set_bytes` **over-reports for I/O-heavy containers**: it counts
active page cache, so anything streaming large files (`qbt-*`, `sabnzbd`, `plex`) grows to
fill whatever limit it is given without ever being at risk — the kernel reclaims that
cache instead of OOMing. Cross-check RSS, the part that cannot be reclaimed:
`PQ 'max_over_time(container_memory_rss{container="main",pod=~"<pod>.*"}[7d])/1024/1024'`.
A large working-set/RSS gap is page cache, not pressure — 🟢, no limit change. `qbt-se/main`
is the standing example: its working set can climb to its limit while RSS stays a fraction
of it, so the working set alone produces a false 🔴.

**CPU**: `request ≈ steady`; the **limit** comes from the throttle ratio, not any peak.
Raise it until throttling stops mattering — a CPU limit is a burst ceiling, and
overshooting costs nothing because CPU is compressible and unused ceiling is never
reserved.

```
PQ 'topk(10,rate(container_cpu_cfs_throttled_periods_total{container!=""}[6h])
     / rate(container_cpu_cfs_periods_total{container!=""}[6h]))'
```

Use the **ratio**, not the raw rate — throttled periods as a fraction of all periods is
comparable across containers. Above ~15% is real. Two traps:

- **A 7d peak cannot corroborate a CPU limit.** Bursty containers (exporters, gRPC
  servers, per-scrape work) show a 5m-rate peak of 2–5m while throttling 20–60%, because
  the burst is far shorter than the sampling window; sizing off the peak reads them as 60×
  over-provisioned when they are starved. For CPU the throttle ratio *is* the evidence.
- **A container younger than the window reads as throttled.** A `[6h]` rate over a pod two
  minutes old is almost all its own startup and ranks at 20–25% with nothing wrong. Check
  pod age (§2) before believing a top-`k` entry, and use `PQR` on that one container to
  confirm a steady pattern rather than a single spike.

Judge on **snapshot _and_ history** (a container idling at 200 Mi that peaked at 8 Gi is
not over-provisioned). 🔴 near-limit and 🟡 under-request are fixed under the gate below;
an applied fix is listed under Output section 4, an unapplied one there as a proposal.

### Applying the sizing changes

**Gate first:** `git -C <repo> status --porcelain`. Empty → edit the `values.yaml` files
with the numbers from the table. Non-empty → **change nothing**; report the proposal as a
diff and say which paths are dirty, so the sizing edits land as a reviewable standalone
diff instead of tangling with work in progress. What may be applied is narrow:

- **Only `resources:` requests and limits** — never images, replicas, probes or args.
- **Only numbers corroborated by history** (7d peak for memory, throttle ratio for CPU).
  No history, no edit. **An `OOMKilled` is itself that history and outranks the peak**:
  the kill is a sub-second spike a 30s-scrape working set never records, so expect the 7d
  peak to sit *well under* the limit on exactly the container that was killed, and raise
  it anyway. Never read a low peak as evidence the OOMKill was spurious. The exception is
  a kill caused by a one-off query burst rather than workload: before raising **Loki**, read
  its `metrics.go` lines with `component=frontend` from the five minutes before the kill. A
  run of multi-hundred-MB `total_bytes` queries from a health check is the check's fault, so
  fix the query and leave the limit alone.
- **No explanatory comments in the YAML** — one changed line per number; the reasoning
  belongs in the report.
- **Never on a node already deep in limit overcommit** without saying so — raise the
  request there and flag the limit increase for the user to decide.

Then stop: Argo syncs from the repo, the user reviews `git diff` and commits. An applied
edit is still a *proposal*, one already written down.

## 4. ArgoCD

`kubectl get applications -n argocd` with sync + health columns; flag anything
not `Synced` + `Healthy`.

## 5. Longhorn (treat as critical — history of unclean-shutdown DB corruption)

```
kubectl get volumes.longhorn.io -n longhorn-system -o json | jq -r '.items[]
  | select(.status.state!="attached" or .status.robustness!="healthy")
  | "\(.status.kubernetesStatus.pvcName // .metadata.name)\t\(.status.state)\t\(.status.robustness)"'
```

Read fields by name, never by column position — `kubectl get` gained a `DATA ENGINE`
column, so a positional `awk` field on its table output tests the wrong column and reports
every volume as broken.

Then confirm the latest run of each recurring `backup`/`snapshot` schedule reached
`Complete`. Read the **Job** objects, not their pods: a node reboot removes completed job
pods while the Job keeps its status, so after rack maintenance a pod grep finds nothing.

```
kubectl get jobs -n longhorn-system -o json | jq -r '.items[]
  | "\(.metadata.name)\t\((.status.conditions // [])[-1].type // "running")\t\(.status.completionTime // "-")"'
```

All four schedules (`daily-backup`, `weekly-backup`, `monthly-backup`, `snapshot-6h`) must
appear. A list covering two silently reports on half the backup system. **This is the only coverage of a
run that failed outright**: `kube_job_failed` needs `backoffLimit: 3` exhausted, and
`failedJobsHistoryLimit: 1` would then pin that alert to a long-superseded run, so no rule
exists. A wholesale failure still reaches §0 as backup age within ~6h; this closes the gap
in between.

**`robustness: healthy` does not mean the data is intact.** Longhorn reports on the block
device and replicates a corrupted filesystem as faithfully as a good one, so a volume
whose ext4 was destroyed by an unclean detach still shows `attached`/`healthy` with every
replica `Running`. The damage surfaces one layer up, as a pod that never starts:

```
LIVE=$(kubectl get pods -A -o json | jq -c '[.items[]|.metadata.namespace+"/"+.metadata.name]')
kubectl get events -A --field-selector reason=FailedMount -o json \
| jq -r --arg t "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" --argjson live "$LIVE" '
  .items[] | select((.series.lastObservedTime // .lastTimestamp // .eventTime // .firstTimestamp) > $t)
  | (.involvedObject.namespace + "/" + .involvedObject.name) as $p
  | select($live | index($p))
  | "\($p)\t\(.message)"' | grep -i fsck
```

The `$live` join is as load-bearing as the time bound: an event stays retained after its
pod is gone and keeps its recent timestamp, so a volume repaired ten minutes ago still
reports a `FailedMount` inside any sane window.

Any `UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY` for a **current** pod is 🔴 regardless of
the volume list, and does not self-heal — replica rebuild copies the damage. Recovery:
`docs/storage-longhorn.md` → "Corrupted volume". Because it takes a mount to notice, this
stays latent for days: a `FailedMount` naming files whose mtimes predate the last reboot
means the corruption is older than the reboot that exposed it, and the snapshots from that
window carry it too — say so, so nobody restores onto the same damage.

### Backup coverage

A `Completed` job pod only proves the job ran; a volume can fail inside a job that reports
success. **Age is the detector**, against the schedule (`daily-backup` 01:00 + 04:00,
`weekly-backup` Sun 02:00, `monthly-backup` 1st 03:00, all local; `snapshot-6h`):

```
PQ '(time()-longhorn_volume_last_backup_at)/3600' \
  | jq -r '.data.result[]|select((.value[1]|tonumber) < 100000)|"\(.metric.pvc_namespace)/\(.metric.pvc)\t\((.value[1]|tonumber)|floor)h"' | sort -k2 -rn
```

The `select` drops the `longhorn-no-bkp` volumes (below): with no backup timestamp,
`time()-0` renders as a six-figure age and sorts above every real result.
`longhorn_volume_last_backup_at` is the newest *completed* backup — the only Longhorn
backup signal that both ignores repaired failures and clears itself.
`LonghornVolumeBackupStale` (30h–3d) and `LonghornVolumeBackupMissing` (>3d) cover it, so
§0 catches a current gap first, and §0's **alert history** catches the ones already
self-healed, which is most of them.

**Gaps** — distinct volumes backed up per day. A day dipping below its neighbours means
volumes were skipped while the job reported `Completed` and the newest-backup timestamp
stayed green. A one-night miss recovers at ~25h, just under the 30h
`LonghornVolumeBackupStale` threshold, so nothing alerts.

Bucket by **local** date: the first pass runs 01:00 local, which under summer time
(`+0200`) is `23:00Z` of the *previous* UTC day — slicing
`snapshotCreatedAt[0:10]` puts the whole run in the day before and makes today look empty,
which reads as a total backup failure when nothing is wrong. One query covers both the
count and the diff; do not re-fetch per day:

```
B=$(kubectl get backups.longhorn.io -n longhorn-system -o json \
  | jq -r '.items[]|select(.status.state=="Completed")|"\(.status.snapshotCreatedAt)\t\(.status.volumeName)"' \
  | while read -r ts vol; do echo "$(date -d "$ts" +%F) $vol"; done | sort -u)
echo "$B" | awk '{print $(1)}' | uniq -c | tail -9      # distinct volumes per local day
comm -23 <(echo "$B"|awk -v d="$(date -d '2 days ago' +%F)" '$(1)==d{print $(2)}') \
         <(echo "$B"|awk -v d="$(date -d yesterday  +%F)" '$(1)==d{print $(2)}')   # what a dip dropped
```

`tail -9` is the point: weekly and monthly backups are retained for months, so the
unbounded list is mostly single-digit historical days that make the recent dailies
unreadable. Map a named volume back to its PVC with
`kubectl get volumes.longhorn.io -n longhorn-system <vol> -o jsonpath='{.status.kubernetesStatus.pvcName}'`.
A count that *matches* its neighbour is not proof the same volumes ran — the set can change
while the size holds, which is why the diff is a separate step.

**Why a volume is behind** (not whether it is) — read only once age or the gap count has
flagged one. No alert is keyed on an `Error` CR, nothing retries a failed volume, and
Longhorn keeps each record for `failed-backup-ttl` (1440m), so the list holds a day of them
and an error can sit beside a later success:

```
kubectl get backups.longhorn.io -n longhorn-system -o json \
  | jq -r '.items[]|select(.status.state=="Error")|"\(.metadata.creationTimestamp)\t\(.status.error[0:160])"'
```

Judge each error against that volume's `longhorn_volume_last_backup_at` — a newer success
means recovered, an older one means still behind. The failure modes and fixes are in
`docs/storage-longhorn.md` → "Backup target errors"; the volume with the largest delta is
the expected casualty of an NFS stall, reliably `plex-config`.

Also watch longhorn-manager (§6) for the backup-target reconcile failing to read the NFS
target. Two messages, both retried forever:

- `Failed to get backupInfo from remote backup target` — a backup *record* that cannot be
  read; it names its volume. An `Error`-state CR drives this in a tight retry loop
  (hundreds of lines a day for one bad record), so match the named volume against the
  `Error` list rather than reading the volume as count evidence. It stops when
  `failed-backup-ttl` evicts the CR, so a high count whose record is under a day old needs
  no action. A named `backup=` with no CR and `… is still in progress` in the error is a
  run in flight inside the 01:00–05:00 backup window and stops when it ends — count only
  what logs after the window.
- `Failed to get info from backup store` … `timeout executing: … system-backup list` — the
  5-minute target reconcile timing out against the NAS. Volume backups can all succeed
  while this fails, so check the volume evidence first. A cluster of these inside a
  **single hour** with no `Error`-state backups is a transient NAS stall — accept it;
  recurrence across separate hours is not.

**Volumes on the `longhorn-no-bkp` StorageClass have no backups _by design_** — disposable
monitoring data, deliberately excluded. Render them ⚪; flagging them as missing-backup is
a **false positive**. Enumerate rather than trusting a written list:

```
kubectl get pv -o json | jq -r '.items[]|select(.spec.storageClassName=="longhorn-no-bkp")|"\(.spec.claimRef.namespace)/\(.spec.claimRef.name)"'
```

### Stuck volume expansion — `attached`/`healthy` hides it completely

A PVC whose size was raised in git can land half-expanded: Longhorn grows the block device,
the *engine* never finishes, the filesystem inside stays at the old size. Every signal
above stays green while `external-resizer` retries forever. Check the claim, not the volume:

```
kubectl get pvc -A -o json | jq -r '.items[]
  | select((.status.conditions//[])[]?.type=="Resizing" or (.spec.resources.requests.storage != .status.capacity.storage))
  | "\(.metadata.namespace)/\(.metadata.name)\twant=\(.spec.resources.requests.storage)\thave=\(.status.capacity.storage)"'
kubectl get volumes.longhorn.io -n longhorn-system -o json \
  | jq -r '.items[]|select(.status.expansionRequired)|"\(.metadata.name)\tspec=\(.spec.size)\texpansionRequired"'
```

🔴 on any hit. Confirm with the engine's `spec.volumeSize` vs `status.currentSize` (equal =
done; different with `EngineMonitor` logging `Starting engine expansion` on a loop = stuck)
and the real filesystem size via `kubectl exec -n <ns> deploy/<app> -- df -h <mountpath>`.

Both queries see only an expansion **still in flight** — the moment it completes (a reboot
completes one as a side effect) they go clean and the incident leaves no trace in any
object's status. The `VolumeResizeFailed` event is the only record it happened:

```
kubectl get events -A --field-selector reason=VolumeResizeFailed -o json | jq -r '.items[]
  | "\(.involvedObject.namespace)/\(.involvedObject.name)\t\(.count // .series.count)x\tfirst=\(.eventTime // .firstTimestamp)\tlast=\(.series.lastObservedTime // .lastTimestamp)"'
```

A hit whose `last` is inside the window but whose PVC now reads `spec == status` is a
**resolved** expansion — report it as such, not a live 🔴, and say what completed it.

The fix is a quiesce cycle, and the two details that decide whether it works (suspend the
root App-of-Apps *first*; wait on the volume reaching `state: detached`, not on the pod
being deleted) are in `docs/pvc-maintenance.md` → "When it gets stuck". Never
`kubectl patch` the PVC or edit the Longhorn volume to paper over it.

**Open monitoring gap** — a stuck expansion is silent between runs. Proposed, not applied:
`LonghornVolumeExpansionStuck`, comparing `longhorn_volume_capacity_bytes` against
`longhorn_volume_actual_size_bytes` on an attached volume for 30m; verify the metric names
against `/api/v1/label/__name__/values` first.

## 6. Log scan (window `W`) — every app, with frequency

**Pass 1 — the sweep.** One Loki query covers *every* namespace (`dashboard`, `tools`,
`metallb-system`, `kube-system` included), so a new or renamed app cannot fall off the
list, and returns the **count per app** that §8's Frequency column needs:

```
W=$0; W=${W:-1h}
case $W in *d) R=1d; N=${W%d};; *) R=$W; N=1;; esac
Q='sum by (namespace, app) (count_over_time({namespace=~".+", app!="coredns"} |~ "(?i)(error|fatal|panic|warn)" != "\"error\":null" != "error=null" !~ "level=info|\"(GET|POST) |HTTP/[12]|warnings.go|is deprecated|caller=metrics.go" ['"$R"']))'
for i in $(seq 0 $((N-1))); do
  kubectl exec -n monitoring deploy/grafana -c grafana -- wget -qO- http://loki:3100/loki/api/v1/query \
    --post-data="query=$(printf %s "$Q" | jq -sRr @uri)&time=$(date -d "$i days ago" +%s)000000000" \
    | jq -r '.data.result[]|"\(.metric.namespace)/\(.metric.app)\t\(.value[1])"'
done | awk -F'\t' '{s[$(1)]+=$(2)} END{for(k in s) print s[k]"\t"k}' | sort -rn
```

**One query over a multi-day window OOMKills Loki**, which takes down the log
store this section reads. coredns' query logging (~50k lines/h) is the bulk of what it would
scan, so it is excluded at the stream selector, and a `d` window runs as sequential one-day
slices.

The `!=`/`!~` filters mirror Pass 2's exclusions. Without them, three kinds of line inflate
the count: structured-log lines whose *success* payload contains the word (`"error":null`),
ingress-nginx access lines whose URL contains it, and longhorn-manager's `level=info`
relays of Warning-type k8s Events. An app then ranks near the top with nothing wrong and
drills down to zero. Any exclusion added to Pass 2
belongs here too, or the ranking lies.

**Establish currency before triaging.** A count is a total over the window and says nothing
about *when*; after a restart the drill-down fills with startup churn that was over in
seconds and looks identical to a fault running all day. Re-run the dominant message over a
short trailing window — zero recent means history:

```
kubectl logs -n "$ns" "$pod" --all-containers --since=20m 2>/dev/null | grep -c '<message>'
```

Three ways this step goes wrong:

- **`--timestamps` prints the node's local time** (`+02:00`), not UTC, so a stamp read
  against a `date -u` window lands two hours off and a burst from half an hour ago reads as
  from the future. klog's own `E0912 05:39` prefix on the *same line* is UTC — the two
  disagree by design. Judge currency with `--since`, which is relative and offset-proof;
  use absolute stamps only to place two events relative to each other.
- **`kubectl logs` cannot see a replaced pod.** Loki's count covers the window; the live
  pod may be minutes old. A Loki count of 40 that drills down to 0 lines usually means the
  lines belong to a pod that no longer exists — check pod age (§2) and read the history
  from Loki, not `--previous`, which reaches only one generation back.
- **Never pass a `-l` selector.** `kubectl logs -l` prints nothing and exits 0 when nothing
  matches, so a guessed label yields a `0` indistinguishable from a burst that ended.
  Loki's labels are not the pods' (`app=longhorn` in Loki is `app=longhorn-manager` on the
  pod) — when unsure, bucket Pass 1's query by `[1h]`, which answers *when* without a
  selector.

Assess frequency as "3 311, all inside the restart minute" or "60/h, ongoing", never a
bare total, and quote it that way when a log line makes the report.

**Every app with a non-zero count gets triaged — including the ones whose count looks
"normal".** A steady 60/h of the same benign line is noise worth fixing at the source (log
level, probe interval, a stale config the app is complaining about). The goal is a **quiet**
log, not merely a fault-free one: noise is what hides the one line that matters. Work down
by count.

**Pass 2 — the drill-down.** Keep the loop shell-agnostic — zsh does not word-split
unquoted parameters: iterate `ns app` pairs (Pass 1's labels) with
`printf '%s\n' … | while read -r ns app`, never `for t in "ns app"; do set -- $t`, which
leaves the second word empty and fails silently, producing empty sections that look like
clean apps.

Read from Loki, not `kubectl logs`: over a window longer than the pod's age (any multi-day
window, or any app a Renovate bump just rolled) `kubectl logs` sees only the live pod and
ranks a fraction of what Pass 1 counted. Loki returns the newest 5 000 lines, so for the
top few apps the ranking covers the tail of the window — pair it with Pass 1 bucketed by
`[6h]` for *when*:

```
sel="{namespace=\"$ns\",app=\"$app\"} |~ \"(?i)(error|fatal|panic|warn)\""
kubectl exec -n monitoring deploy/grafana -c grafana -- wget -qO- http://loki:3100/loki/api/v1/query_range \
  --post-data="query=$(printf %s "$sel" | jq -sRr @uri)&limit=5000&since=$W" \
  | jq -r '.data.result[].values[][1]' \
  | sed 's/\x1b\[[0-9;]*m//g' \
  | grep -iE '\b(error|fatal|panic|warn(ing)?)\b|level=(error|warn)|"level":"(error|warn|fatal)"|(^|[[:space:]])E[0-9]{4}[[:space:]]|\[(error|crit)\]' \
  | grep -ivE '"error":null|error=null|level=info|caller=metrics\.go|warnings\.go|is deprecated|"GET |"POST |HTTP/[12]' \
  | sed -E 's/[0-9]{4}-[0-9-]*T?[0-9:.]*Z?//g; s/\b[EWIF][0-9]{4} [0-9:.]+ +[0-9]+\b//g; s/[0-9]{2}:[0-9]{2}:[0-9]{2}//g; s/[0-9]+/N/g' \
  | cut -c1-180 | sort | uniq -c | sort -rn | head -10
```

Every transform is load-bearing. The four `sed` substitutions (ISO stamps, klog
`W0827 11:31:11.275065       1`, bare `HH:MM:SS`, and the blanket `[0-9]+`→`N` for IPs,
ports, durations, IDs) are what let `uniq -c` rank anything — any format left un-normalized
makes every line unique and returns a column of `1`s. `cut -c1-180` keeps a failed
`helm template`, which echoes its entire `--api-versions` list, from burying the section in
thousands of characters. Both cost readability, the right trade for a ranking pass — read
raw lines for the one message that matters. A message seen once and one seen 4 000 times
need different responses, so the count must survive into §8.

Match on **log-severity markers**, not bare substrings (`fail` matches the `failed_only`
query param in nginx access logs; `error` matches `"error":null`).

If Loki is down, feed `kubectl logs -n "$ns" "$pod" --all-containers --prefix --since="$W"`
into the same pipeline for every pod of every namespace from `kubectl get ns` (not a
hardcoded list), and say in the report that the sweep ran degraded and blind to replaced
pods.

## 7. Pi-hole HA (dual resolver + VIP)

Active/standby on `pihole-01` (`.51`/`::51`, normal master) and `pihole-02` (`.52`/`::52`),
sharing keepalived VIPs `10.10.53.53` / `::53`:

```
for h in pihole-01 pihole-02; do echo "### $h"; ssh -o ConnectTimeout=5 "$h" '
  for s in pihole-FTL unbound keepalived; do printf "%s=%s " "$s" "$(systemctl is-active $s)"; done; echo
  ip -4 addr show eth0 | grep -q 10.10.53.53 && v4=MASTER || v4=backup
  ip -6 addr show eth0 | grep -q 1c35::53 && v6=MASTER || v6=backup
  echo "vip_v4=$v4 vip_v6=$v6"
  dig +short +time=2 +tries=1 @127.0.0.1 pi.hole >/dev/null 2>&1 && echo "FTL_answering=yes" || echo "FTL_answering=NO"
  echo "nebula-sync=$(systemctl is-active nebula-sync 2>/dev/null)"'; echo; done
```

Healthy = exactly one node holds each VIP, both FTL answering, `nebula-sync` active on
pihole-01 only (inactive/not-found on pihole-02 is correct). Flag (carry to §8):

- 🔴 **No master** — neither node holds a VIP: DNS is down network-wide.
- 🔴 **Split-brain** — both hold the same VIP: IP conflict.
- 🔴 **FTL not answering** on a node whose process is `active` — the wedged-FTL mode (often
  after a heavy nebula-sync); `sudo systemctl restart pihole-FTL` there.
- 🟡 **Failover active** — pihole-02 holds the VIP: pihole-01 or its FTL is down;
  investigate why it didn't preempt back.
- 🟡 **v4/v6 split** — the VIPs sit on different nodes (the sync group should keep them
  together).
- 🟡 **nebula-sync** not `active` on pihole-01, or its last run failed
  (`journalctl -u nebula-sync -n 20`): replica config drifts.

## 8. Warnings sweep & assessment

Aggregate **every** warning — §0's firing alerts plus the ones that
fired and cleared, the k8s warning events **bounded to the window**, §6's log lines **with
counts**, §1's threshold breaches, §2's silent failures, §3's near-limit / under-request
rows, §7's Pi-hole breaches — then assess each one.

Events must be time-filtered explicitly, and on the right field. `kubectl get events`
returns the full retained history; events from the `events.k8s.io` API carry
`lastTimestamp: null` (the timestamp lives in `eventTime`), so filtering on `lastTimestamp`
silently keeps them — unfiltered, an 11-day-old `ImageGCFailed` and a cordon-storm of
`FailedScheduling` from the last rack maintenance both read as current. And for a repeating
event **`eventTime` is the *first* observation**, the last living in
`.series.lastObservedTime`, so filtering on `eventTime` fails both ways: it collapses a
long burst to one line at the wrong instant, and drops an event still firing whenever the
series began before the window. Coalesce last-first, and read the span, not a point — a
large `count` whose first and last differ by hours is one past incident; the same count
with a last observation minutes old is live.

```
kubectl get events -A --field-selector type=Warning -o json | jq -r --arg t "$(date -u -d '12 hours ago' +%Y-%m-%dT%H:%M:%SZ)" '
  .items[] | (.series.lastObservedTime // .lastTimestamp // .eventTime // .firstTimestamp) as $last
  | (.eventTime // .firstTimestamp // $last) as $first
  | select($last != null and $last > $t)
  | "\($last)\t\(.reason)\t\(.involvedObject.namespace)/\(.involvedObject.name)\t\(.count // .series.count // 1)x\tsince=\($first)\t\(.message[0:100])"' | sort
```

(substitute the run's window for `12 hours ago`.) Assess each warning as **🔧 fixable**
(with the concrete GitOps fix), **✅ accept** (known-benign, or a transient that left
nothing degraded), or **⚪ standing** (already accepted with an exit trigger). 🔧 items go to
Output section 2 (broken or breaking) or 3 (noise and warnings); ✅ and ⚪ never appear.

Judge **frequency** from §6's counts, not impressions — "60/h" and "1 in the window" get
different verdicts. **High-volume benign noise with a ready fix** (a log level, a config
key the app complains about) goes to Output section 3; noise without a fix
goes on the benign list below so the next run doesn't re-derive it.

### Known-benign — drop these before reporting

- nginx `upstream timed out` on `/api/events?stream=` / IRC SSE — an open autobrr/UI
  browser tab hitting the 60s read-timeout.
- autobrr `debug` filter "rejected"/rate-limit lines — working as intended.
- nginx access-log lines (2xx/3xx) — not errors, and they contain apikeys. **Generalizes:
  never echo secret material into the report.** Container env (`*_VAR_*`, `*_KEY`,
  `*_TOKEN`, `*_PASSWORD`) holds live credentials in plaintext, so when a config check
  needs one, grep for that single variable instead of dumping the block.
- loki query-stats (`caller=metrics.go`, `level=info`) and coredns `[INFO]`/`[WARNING]`
  query logs — telemetry, not faults. coredns query logging is deliberately on, which is
  why Pass 1 excludes it at the selector.
- `loki-canary` `tail max duration limit exceeded` — canary recycling its tail. Loki logs
  the same recycle from its side as `Error from iterator` … `reached tail max duration
  limit` and `Error receiving response from grpc tail client` … `context canceled`, ~70/day
  each.
- loki `could not determine query overlaps on tsdb vs non-tsdb schemas` with `start` and
  `end` under a second apart on a quarter-hour — loki-canary's once-a-minute spot-check
  queries of its own entries, a steady ~2/min that ranks loki near the top of Pass 1.
- **droppedneedle** `slskd file not locatable on the downloads mount` — logged every poll
  while a slskd transfer for that file is still in flight or failing; it names the file
  slskd's own log shows retrying. The real harm in that area is orphans under
  `/media/dl/music`, which make slskd write `_<ticks>` renames, not this line.
- k8s API deprecation `Warning:` lines from longhorn-manager/controllers — upstream
  chatter. Covers `v1 Endpoints is deprecated` and the high-volume
  `metadata.finalizers: prefer a domain-qualified finalizer name` alike.
- plex `## IGNORE THE ERROR MESSAGE:  ##` — the container's own startup banner, matched by
  the word `ERROR`; and plex's transcoder printing its ffmpeg build line
  (`configuration: … --fatal-warnings …`) once per transcode, matched by `warn`.
- argocd-repo-server `found in Chart.yaml, but missing in charts/ directory` — the first
  `helm template` of each umbrella chart at a new git revision; the repo-server then builds
  dependencies and retries. One burst per app per commit, so it tracks Renovate merges.
- ingress-nginx `local SSL certificate <ns>/<app>-tls was not found` and cert-manager
  `re-queuing item due to optimistic locking` for an Ingress created in the window — the
  minutes before cert-manager issues its first certificate. Accept only if
  `kubectl get certificates -A` is all `Ready=True` now.
- gluetun (qbt/sabnzbd VPN sidecars) `WARN [dns] ... connection reset by peer` /
  `renewing dead connection` to Quad9 `:853` — transient DoT hiccups it self-heals. It runs
  every day at ~1 000/day on `qbt-se` and a few hundred on the other gluetuns, so
  "persistent" alone is not a trigger: flag it only if downloads stall or a pod's daily
  count jumps tenfold.
- longhorn-manager `Error syncing snapshot check task` … `is hashing snapshot` — a
  burst of thousands on the `snapshot-data-integrity-cronjob` days (`0 0 */7 * *`: the
  1st/8th/15th/22nd/29th, 00:00 UTC) as concurrent hash requests for one volume retry each
  other. A real finding only if it appears on another day or names a hash *mismatch*.
- instance-manager `fail to read at 0 for N` / `Cannot queue in more request. Connection
  is not open` / `io error … -14` — the engine frontend dropping in-flight I/O as a volume
  detaches. Benign when it lands in the minute a pod using that node's volume was
  replaced (Renovate rollouts, ~07:00 local); outside a pod move it is a replica fault.
- instance-manager `Trying reading mount point /var/lib/longhorn-backupstore-mounts/… to
  make sure it is healthy` — Longhorn's routine probe of the NFS backup target before each
  backup, logged at warning level, so it tracks the backup schedule (~100/day). A
  probe that *fails* shows up as a backup `Error` CR in §5.
- **WAN outage signature** — every VPN gluetun logging `restarting VPN because it failed to
  pass the healthcheck` … `lookup <host>: i/o timeout` in the same minute, alongside
  argocd-repo-server `failed to list refs` and pulsarr RSS failures, with node links and
  in-cluster traffic fine. The gateway confirms it if needed (`ssh UGCMax 'grep
  "^<date>T<HH:MM>" /var/log/daemon.log*'`: repeated `udhcpc: sending renew` on the WAN
  interface with no reply). The ISP side is out of reach; the gluetun container restarts it
  leaves (`Completed`, exit 0) are not churn.
- kubelet `FreeDiskSpaceFailed` (`Failed to free sufficient space by deleting unused
  images`) during an image-pull wave — image GC lands just above its 80% low threshold
  because the rest is in-use images. Benign while `/` holds its 14-day band (§1's
  `NodeRootDiskFillingUp` catches a real trend).
- **qui** orphan-scan `failed` on `qbt-br` — cosmetic: qui has no `/local` mount and br
  always has active downloads, and qui marks any run with walk errors and zero orphans as
  failed. Not fixable via Ignore Paths; never mount `/local` into qui.
- **pulsarr** `ERROR: [WATCHLIST_WORKFLOW] Failed to fetch RSS feed` (≈0.7% of polls) — it
  polls `rss.plex.tv` every ~10 s with a hardcoded 30 s timeout and occasional Plex-side
  latency trips it; the 120-min full reconciliation is a separate path and always succeeds,
  so nothing is missed. Timeout and severity are hardcoded upstream. Escalate only if full
  reconciliation also starts failing.
- **Startup churn in the minute after a restart** — a node reboot *or* a control-plane
  component redeploy (an Ansible/Helm run reinstalling cert-manager or argocd reproduces it
  identically). Always the same set: cert-manager `ACME client for issuer not initialised`,
  longhorn-manager `mismatching disks`, the CSI sidecars' `dial unix /csi/csi.sock:
  connect: connection refused`, promtail readiness-probe timeouts and `final error sending
  batch` … `entry too far behind` (it re-sends days-old entries Loki already holds), qui
  `instance is in backoff period` — each a controller reconciling ahead of its dependency, all
  self-clearing. **Accepted only when confined to the restart window**: establish that with
  §6's currency check, and confirm the end state with `kubectl get clusterissuer` +
  `kubectl get certificates -A` (all `Ready=True`) and `kubectl get nodes.longhorn.io -n
  longhorn-system` (every disk `Ready`/`Schedulable`). The same message 20 minutes later is
  a real finding.

### Standing accepted conditions

**Real** conditions knowingly accepted for now, each with an explicit trigger that ends the
acceptance. They are left out of the report, but every re-open trigger is evaluated every
run, and if one fires the row becomes a 🔴 item.

| Since      | Condition                                                                                      | Why accepted                                                | Re-open when                                                         |
| ---------- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------- | -------------------------------------------------------------------- |
| 2026-08-19 | DAS drives `sda`/`sdb` run hot: `DiskTemperatureHigh`/`Critical` and `DasDiskLatencyImbalance` | Known; ignored until the user's enclosure airflow fix lands | Any reallocated or pending sector on `sda`/`sdb` (RAID 0, no backup) |

Baseline at acceptance (2026-11-22): steady 52/54 °C (sda/sdb), 7d peaks 60/61 °C under a
sustained transfer, zero reallocated and pending sectors. Once the airflow fix lands,
re-measure a warm week against this baseline and retire the row.

Adding a row here needs both the re-open trigger and the baseline, or it is not an
acceptance but a blind spot. Permanent by-design exemptions (`/mnt/r0` full, k3s-server's
phantom load) belong inline as ⚪ in their own section — this table is only for conditions
meant to end.

Surface anything that survives this filter (repeated `x509`/auth failures, OOMKills, real
`panic`, a *new* app erroring, a disk crossing 90%).

## Output

Four sections, always in this order and always present (an empty one reads `None.`). Every
entry carries an ID — section number plus letter (`1a`, `2b`, `3c`) — so the user can refer
to it. IDs hold within one report only; this check keeps no state between runs.

### 1. Summary

One table, the same rows in the same order every run so runs compare at a glance:
`ID | Area | Status | See`. **Status** is 🟢 healthy / 🟡 warning / 🔴 broken / ⚪ accepted
or by-design. **See** is empty when 🟢, otherwise the item it points to (`→ 2a`, `→ 3b`) or
`standing` for ⚪. No descriptions. Rows:

| Area              | Section | Status comes from                                                               |
| ----------------- | ------- | ------------------------------------------------------------------------------- |
| Alerts            | §0      | firing alerts and scrape health                                                 |
| Nodes             | §1, §2  | Ready, pressure conditions, CPU/mem/PSI/iowait, D-state, failed units, AppArmor |
| Disk space        | §1      | every mount except `/mnt/r0`                                                    |
| NFS mounts        | §1      | `/mnt/nas/media` alive, no wedge                                                |
| DAS drives        | §8      | standing row — ⚪ until its re-open trigger fires                                |
| Pods              | §2      | not Running, not ready, restarts, silent failures                               |
| VPN port-forwards | §2      | gluetun forwarded port = qBittorrent listen port                                |
| Resources         | §3      | near-limit, under-requested, OOM kills                                          |
| ArgoCD            | §4      | every app Synced + Healthy                                                      |
| Longhorn volumes  | §5      | state, robustness, fsck, stuck expansion                                        |
| Backups           | §5      | schedules complete, backup age, daily gaps                                      |
| Pi-hole DNS       | §7      | VIPs, FTL answering, nebula-sync                                                |
| Logs              | §6      | 🟢 quiet · 🟡 cleanable warnings in section 3 · 🔴 a fault that is in section 2    |

Transients that self-healed with nothing left degraded (network blips, WAN outages, restart
bursts, alerts that fired and cleared) leave their row 🟢 and appear nowhere else. Check the
end state (pods ready, volumes healthy, port-forwards matched, backups current) before
calling one self-healed; if it left damage, the damage is the item.

### 2. Needs attention

What is broken now or will break without action: a service down or degraded, data at
risk (a volume degraded, a backup gap, fsck failure), DNS down, a firing alert that isn't
standing, a trend crossing a threshold within about a week. Each entry `2a`, `2b`, … leads
with 🔴/🟡 and a bold one-line title, then a few lines: what is wrong and since when, the
impact or deadline with the number that shows it, and the fix as an exact file change or
command (never applied to the cluster). Worst first.

### 3. Outstanding warnings

Log noise and warnings that can be stopped at the source — anything §6/§8 found with a
feasible fix. Unfixable benign lines go on §8's known-benign list instead, never here. One
table, highest frequency first:
`ID | Service | Warning | Frequency | Effort | Fix`, where Frequency is a rate ("60/h",
"1/start") and Fix is the file and change. **Effort** (1–10) uses fixed anchors:

| Effort | Means                                                         |
| ------ | ------------------------------------------------------------- |
| 1–2    | one-line `values.yaml` or Argo-synced config edit             |
| 3–4    | a few edits or an app setting changed in its UI               |
| 5–6    | an Ansible playbook run, or a change needing a rollout window |
| 7–8    | a new component, or an upstream issue/PR                      |
| 9–10   | hardware or physical work                                     |

### 4. Changes made

One line per change this run wrote to the repo, in words: "raised loki-sc-rules memory
request 80→96Mi", "skill: accept-listed X". No diffs — the user reads `git diff`. When the
tree was dirty, list the proposals here as `Proposed (not applied, tree dirty): …`, also in
words.

## Skill feedback (every run)

Before reporting, work out what this run taught the check itself: a false positive to
accept-list, a manual command the sweep should have run, a miss a section should have
caught, a threshold that deserves a Prometheus rule. "Nothing to change" is valid; not
looking is not. **Apply the edit under §3's gate** — clean tree at the start of the run →
edit this file; dirty → propose the diff and change nothing. A finding left as a proposal
is one the next run re-derives. In the report it is a line in Output section 4.

**Most findings do not belong in this file.** Write here only what **changes how a future
run behaves**: a check it would otherwise not run, a false positive it would otherwise
re-derive, a threshold, a failure mode with a named fix, a command that was wrong. Keep out
**this run's measurements** (readings age into lies — the exception is a standing
condition's baseline, which exists to be compared against), **narrated history** ("X did
not work", "this used to be Y" — state what *is*; one clause is enough to stop a ruled-out
fix being re-proposed), **illustrative examples** that are not themselves the recurring
false positive, and **decisions still being weighed** (bring those to the user; what lands
here is the resulting rule). Everything else belongs in the report, said once.

A durable finding that is *not* a change to this check — a real threshold, a failure mode,
a recovery procedure — belongs in `docs/`. Keeping the explanation there and the detector
here is what stops this file becoming a second copy of `docs/storage-longhorn.md`.

**Then sweep this whole file — every run, not just the ones that changed it.** It grows by
accretion: each run bolts on a finding and nothing removes anything. Read it end to end and
fix:

- **Contradiction** — two passages that cannot both be followed, including a threshold here
  that disagrees with its alert rule. The newest is usually right and the older usually
  needs *scoping*, not deletion.
- **Duplication** — the same guidance in two sections, or a passage restating a `docs/`
  page. Keep it where it is acted on, cross-reference from the other.
- **Staleness** — a literal reality has moved past: a grep string the logs no longer emit,
  a regex missing a job that now exists, a hardcoded percentage, a renamed path, a
  `kubectl` column that shifted. Every literal here is a claim about the cluster; verify the
  ones this run touched.
- **Hardcoded lists** — nodes, namespaces, apps, volumes enumerated by hand. Replace with
  the discovery query.
- **Expired notes** — anything with a date or a re-evaluate-by. Act when due, then *delete*
  it; a dated note left past its date reads as current.
- **Cost** — a command making N round-trips where one would do (per-node SSH passes,
  per-day `kubectl` calls). Every run pays it.
- **Bloat** — a measurement, a narrated incident, an example carrying no rule, a proposal
  already applied or declined. Cut it, keep the rule.
- **Argument substitution** — this file is a slash command: before it is read, Claude Code
  replaces every `$` followed by a digit with the invocation's words (0-based, so the
  window is the zeroth). Write awk fields as `$(1)` and shell positionals as `${1}`; a
  bare one arrives as a word of the user's message and the command fails or lies.
- **Ambiguity** — a threshold with no unit, a verdict with no owning section, an instruction
  whose subject is unclear on a cold read.

What the sweep changed is a line in Output section 4; a sweep that changed nothing is not
mentioned.

**Repetition is itself a finding.** This file is the check's only memory:

- A warning assessed **✅ accept for the same reason more than twice** → promote it to a
  standing accepted condition (with a re-open trigger) or to the benign-lines list.
- A **🔧 fixable that keeps reappearing unfixed** → note in the item how many runs it has
  survived, as escalation rather than a fresh finding. Either it is harder than it looked (write
  down why) or it deserves an alert rule so it stops depending on this check.
- A standing condition whose **numbers drifted** past its baseline → re-open it, unless its
  row names its own re-open trigger instead.
- Something that fires **every run and is always fine** → the threshold is wrong, not the
  cluster. Propose the corrected threshold, here or in `prometheus/values.yaml`.
