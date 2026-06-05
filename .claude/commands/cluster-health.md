---
description: Read-only health sweep of the k3s cluster (node metrics, pods, ArgoCD, Longhorn, warnings)
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
accepted (see §6).

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
with a **Status** column — 🟢 ok / 🟡 warning / 🔴 critical — so the state of each
node/mount is scannable at a glance (a row's status = its worst breached metric):

- **Compute** — one row per node: `Status | Cores | Load 1/5/15 | Load÷core | CPU busy% | iowait% | Blk I/O in/out | Mem`.
  `Load÷core` (load15 ÷ cores) is the real saturation signal, not raw load.
- **Disk** — one row per mount (`Status | Mount | Size | Used | Use%`) for `/`,
  `/boot`, `/mnt/nvme/longhorn`, and the node-specific `/mnt/ssd/local`,
  `/mnt/nvme/local`, `/mnt/r0` per docs/hardware.md.

Flag with thresholds (these are warnings — carry to §6):
`Load÷core` 🟡 >1.0 / 🔴 >2.0 sustained · `CPU busy` 🟡 >85% · `iowait` 🟡 >20% ·
`Mem` 🟡 >90% · `Disk` 🟡 ≥85% / 🔴 ≥90%. The 40 GiB `/` partitions trend high
(containerd image cache in `/var/lib/k3s/agent`); note ≥85% but know kubelet
image-GC self-prunes around 85% of the image filesystem.

## 2. Node conditions & pods

- `kubectl get nodes -o wide`; flag any `*Pressure=True` or not `Ready`.
- `kubectl get pods -A`; flag anything not `Running`/`Completed`
  (CrashLoopBackOff, Pending, Error, OOMKilled, ImagePullBackOff).
- **Restarts:** list containers with `lastState.terminated.finishedAt` in the
  last ~24h (`kubectl get pods -A -o json | jq`). Old restart counts that all
  trace to a single past timestamp = a prior planned reboot, **not** churn — say
  so rather than alarming. Only recent/repeating restarts matter.

## 3. ArgoCD

`kubectl get applications -n argocd` with sync + health columns; flag anything
not `Synced` + `Healthy`.

## 4. Longhorn (treat as critical — history of unclean-shutdown DB corruption)

Volume `robustness`/`state` (flag non-`healthy`/non-`attached`); confirm the
recurring `backup`/`snapshot` **job** pods reached `Completed`. Match the
timestamped job pods only (`grep -E 'daily-backup-|snapshot-[0-9]'`) — NOT the
always-`Running` `csi-snapshotter` controller pods.

## 5. Log scan (window `$1`)

Across `media`, `longhorn-system`, `kube-extra`, `cert-manager`, `argocd`. Match
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

## 6. Warnings sweep & assessment (the headline section)

Aim: warning-free. Aggregate **every** warning from all sources — `kubectl get
events -A --field-selector type=Warning`, the WARN/ERROR log lines from §5, and
the metric-threshold breaches from §1 — then assess each one. Present a table:

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
table rows, per-area lines) so status is scannable at a glance. Use ⚠️ inline
when calling out a specific warning in prose.

1. One-line **verdict** (🟢 healthy / 🟡 N warnings / 🔴 issues).
2. The two **node-metrics tables** from §1 (the glanceable part), each row led by
   its 🟢/🟡/🔴 Status column.
3. Short **per-area** lines (pods / ArgoCD / Longhorn) each prefixed with a
   🟢/🟡/🔴 marker.
4. The **Warnings & assessment** table from §6 — the focus. For 🔧 fixable ones,
   propose the change as code/commands; **don't apply** — per repo policy all
   changes are GitOps/IaC and the user runs them.

If everything is green, say so plainly — don't invent work.
