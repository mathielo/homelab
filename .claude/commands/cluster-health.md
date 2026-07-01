---
description: Read-only health sweep of the k3s cluster (node metrics, pods, resource balance, ArgoCD, Longhorn, warnings)
argument-hint: "[log window, e.g. 1h, 6h — default 1h]"
allowed-tools: Bash(kubectl get:*), Bash(kubectl top:*), Bash(kubectl logs:*), Bash(kubectl describe:*), Bash(ssh:*), Bash(jq:*), Bash(grep:*), Bash(sed:*), Bash(awk:*), Bash(echo:*), Bash(tail:*), Bash(cut:*), Bash(sort:*), Bash(for:*)
---

Run an on-demand, **read-only** health check of the homelab k3s cluster and give
me a structured report. Never mutate anything — `kubectl get`/`top`/`logs`/
`describe` and read-only `ssh` OS inspection only. Log scan window: `$1`
(default `1h` if empty).

Run the checks below (batch independent commands in parallel), then **interpret**
the results — don't just dump raw output. Apply judgment: separate real problems
from known-benign noise. The standing goal is a **warning-free environment**, so
actively hunt warnings and, for each, decide whether it's fixable or must be
accepted (see §8).

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

Flag with thresholds (these are warnings — carry to §8):
`Load÷core` 🟡 >1.0 / 🔴 >2.0 sustained · `CPU busy` 🟡 >85% · `iowait` 🟡 >20% ·
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

## 3. Resource right-sizing (requests/limits balance)

Right-size the workloads: catch containers that are **starved** (near their limit,
or using more than they request) or **bloated** (reserving far more than they ever
touch). Two data sources, joined per `namespace/pod/container`:

- **Live usage** (metrics-server snapshot — millicores + MiB):
  `kubectl top pods -A --containers --no-headers`
- **Configured requests/limits**:
  `kubectl get pods -A -o json | jq -r '.items[]|.metadata.namespace as $ns|.metadata.name as $p|.spec.containers[]|[$ns+"/"+$p+"/"+.name,(.resources.requests.cpu//"-"),(.resources.limits.cpu//"-"),(.resources.requests.memory//"-"),(.resources.limits.memory//"-")]|@tsv'`

Join them (awk on the `ns/pod/container` key, no temp files) and, per container,
reason about `mem %R = use/request`, `mem %L = use/limit`, and `cpu %R = use/request`:

```
awk -F'\t' 'NR==FNR{r[$1]=$2" "$3" "$4" "$5; next} ($1 in r){print $1"\t"$2"\t"$3"\t"r[$1]}' \
  <(kubectl get pods -A -o json 2>/dev/null | jq -r '.items[]|.metadata.namespace as $ns|.metadata.name as $p|.spec.containers[]|[$ns+"/"+$p+"/"+.name,(.resources.requests.cpu//"-"),(.resources.limits.cpu//"-"),(.resources.requests.memory//"-"),(.resources.limits.memory//"-")]|@tsv' | sort) \
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

**Snapshot caveat:** `kubectl top` is a single point in time — right-sizing needs a
*trend*. Treat %R/%L here as a **lead**, not proof. Before proposing a manifest
change, corroborate with the Prometheus/Grafana history (the cluster runs
Prometheus) or with OOMKilled / CPU-throttle events. Never churn limits off one
reading. For each actionable row, name the exact `values.yaml` and the suggested
number. Carry 🔴 near-limit and 🟡 under-request rows into the §8 sweep as 🔧
fixable; keep over-provisioning as a separate optimization note.

## 4. ArgoCD

`kubectl get applications -n argocd` with sync + health columns; flag anything
not `Synced` + `Healthy`.

## 5. Longhorn (treat as critical — history of unclean-shutdown DB corruption)

Volume `robustness`/`state` (flag non-`healthy`/non-`attached`); confirm the
recurring `backup`/`snapshot` **job** pods reached `Completed`. Match the
timestamped job pods only (`grep -E 'daily-backup-|snapshot-[0-9]'`) — NOT the
always-`Running` `csi-snapshotter` controller pods.

## 6. Log scan (window `$1`)

Across `media`, `monitoring`, `longhorn-system`, `kube-extra`, `cert-manager`,
`argocd`. Match
on **log-severity markers**, not bare substrings (`fail` matches the `failed_only`
query param in nginx access logs; `error` matches `"error":null`). Strip ANSI
first, then grep severity:

```
kubectl logs -n "$ns" "$pod" --all-containers --prefix --since="$1" 2>/dev/null \
  | sed 's/\x1b\[[0-9;]*m//g' \
  | grep -iE '\b(error|fatal|panic|warn(ing)?)\b|level=(error|warn)|"level":"(error|warn|fatal)"|[[:space:]]E[0-9]{4}[[:space:]]|\[(error|crit)\]' \
  | grep -ivE '"error":null|error=null|level=info|caller=metrics\.go|warnings\.go|is deprecated|"GET |"POST |HTTP/[12]' \
  | tail -5
```

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

Aim: warning-free. Aggregate **every** warning from all sources — `kubectl get
events -A --field-selector type=Warning`, the WARN/ERROR log lines from §6, the
metric-threshold breaches from §1, the near-limit / under-request rows from §3,
and the Pi-hole HA breaches from §7 — then assess each one. Present a table:

`Source | Warning | Frequency | Assessment`

where Assessment is one of: **🔧 fixable** (give the concrete GitOps fix to
propose) or **✅ accept** (known-benign; say why). Drop the known-benign lines
below before reporting — they're already assessed as accept:

- nginx `upstream timed out` on `/api/events?stream=` / IRC SSE — an open
  autobrr/UI browser tab hitting the 60s read-timeout, not a fault.
- autobrr `debug` filter "rejected"/rate-limit lines — working as intended.
- nginx access-log lines (HTTP requests with 2xx/3xx status) — not errors; they
  also contain apikeys, so never echo them into the report.
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
- **pulsarr** `ERROR: [WATCHLIST_WORKFLOW] Failed to fetch RSS feed` (≈0.7% of
  polls) — Pulsarr polls the Plex watchlist RSS (`rss.plex.tv`, S3-backed) every
  ~10 s with a hardcoded 30 s timeout; occasional Plex-side latency trips it.
  The endpoint is reachable from the pod and the 120-min full reconciliation (a
  separate path) always succeeds, so nothing is missed. Timeout + ERROR severity
  are hardcoded upstream — not config-fixable; **accept**. Only escalate if full
  reconciliation also starts failing.

Surface anything that survives this filter (e.g. repeated `x509`/auth failures,
OOMKills, real `panic`, a *new* app erroring, a disk crossing 90%).

## Output

Use the 🟢 / 🟡 / 🔴 traffic-light system everywhere state is reported (verdict,
table rows, per-area lines) so status is scannable at a glance — plus ⚪ for
by-design rows that are deliberately exempt from their threshold (e.g.
`/mnt/r0`). Use ⚠️ inline when calling out a specific warning in prose.

1. One-line **verdict** (🟢 healthy / 🟡 N warnings / 🔴 issues).
2. The two **node-metrics tables** from §1 (the glanceable part), each row led by
   its 🟢/🟡/🔴 Status column.
3. Short **per-area** lines (pods / ArgoCD / Longhorn) each prefixed with a
   🟢/🟡/🔴 marker.
4. The **resource right-sizing table** from §3 — 🔴 near-limit and 🟡
   under-request rows first (with the exact `values.yaml` + suggested number),
   then any over-provisioned trims as optimizations. Skip the section only if
   nothing is off in either direction (say so in one line).
5. The **Warnings & assessment** table from §8 — the focus. For 🔧 fixable ones,
   propose the change as code/commands; **don't apply** — per repo policy all
   changes are GitOps/IaC and the user runs them.

If everything is green, say so plainly — don't invent work.
