# Monitoring & Dashboards

Prometheus, Alertmanager, Loki, Promtail and Grafana are deployed by ArgoCD from
`k3s/apps/monitoring/`. Grafana is at [`grafana.m6o.dev`](https://grafana.m6o.dev).

## Scrape jobs

`kubernetes-api-servers`, `kubernetes-nodes` (kubelet), `kubernetes-nodes-cadvisor`,
`kubernetes-pods`, `kubernetes-service-endpoints` (node-exporter + kube-state-metrics),
plus two explicit jobs in `prometheus/values.yaml`:

| Job       | Target                                     | Why it needs an explicit job                            |
| --------- | ------------------------------------------ | ------------------------------------------------------- |
| `longhorn`| `longhorn-backend` endpoints, `manager` port| Annotation-based discovery doesn't pick the manager up   |
| `pihole`  | `10.10.53.51:9100`, `10.10.53.52:9100`      | The Pis are standalone hosts, not cluster nodes          |

### Label conventions (these bite when writing queries)

- **node-exporter** carries `node="k3s-node-02"`. The `pihole` job sets `node` by
  hand in its `static_configs` labels so one dashboard variable spans all five hosts.
- **kubelet** metrics (`kubelet_volume_stats_*`) use `instance="k3s-node-02"` and
  carry **no** `node` label — filter those by `instance`, not `node`.
- `kubelet_volume_stats_*` is scraped by **both** `kubernetes-nodes` and
  `kubernetes-api-servers`, so every PVC appears twice. Pin queries to
  `job="kubernetes-nodes"` or `topk` returns the same volume repeatedly.
- `longhorn_volume_robustness` is reported by **every** longhorn-manager, so each
  volume has ~4 series and only the owning manager's is meaningful (the rest read
  `0`). Deduplicate with `max by (volume) (...)`.
- Community dashboards from grafana.com generally assume the kube-prometheus-stack
  job names (`node-exporter`, `kubelet`, `cadvisor`) and will render "No data" here.
  Prefer extending the custom dashboards below.

## Dashboards

Custom dashboards are plain JSON under `k3s/apps/monitoring/grafana/dashboards/`.
`templates/dashboards.yaml` globs that directory into a ConfigMap, and
`grafana.dashboardsConfigMaps` mounts it as the `homelab` provider — **adding or
removing a file needs no `values.yaml` change.** The upstream grafana chart is a
`.tgz` dependency, which is why the JSON can't live inside it.

| Dashboard          | UID                | Purpose                                                             |
| ------------------ | ------------------ | ------------------------------------------------------------------- |
| Homelab Overview   | `homelab-overview` | Full-detail cluster + Pi-hole view for a desktop browser             |
| Rack Kiosk         | `rack-kiosk`       | 1280×400 layout for the rack touchscreen                             |
| Pi-hole HA         | `pihole-ha`        | VIP ownership, resolver health, keepalived state                     |

Community dashboards (node-exporter Full `1860`, Loki Log Explorer `13639`) are
still pulled by `gnetId` under the separate `default` provider.

### Homelab Overview

Rows: Fleet → Scheduling headroom → Host vitals → Storage → Thermals & network →
Top talkers → Pi-hole HA. A `$node` variable filters the host-level rows.

Two panels are worth knowing about:

- **Scheduling headroom** shows CPU/memory *requests* against allocatable, counting
  only Running pods. This is what decides whether another workload fits — it is not
  a usage graph. "Pod slots used" tracks the kubelet's 110-pod-per-node cap, the
  third ceiling that can block scheduling while CPU and memory look free.
- **Pressure stall (PSI)** is the honest contention signal on these boxes.
  k3s-server's load average spikes to 10–20 from thread churn while CPU, iowait and
  PSI stay flat — read PSI, not `node_load1`.

### Rack Kiosk

Sized for the DeskPi 7.84" panel (1280×400) on k3s-node-02 — see below. Two rows of
five grid units is the whole budget, so **new panels have to replace existing ones**
rather than be appended, or they fall below the fold. No legends or axes: it is read
from across the room, and the threshold colours carry the meaning.

`/mnt/r0` is excluded from the "fullest disk" tile because it runs near-full by
design and would otherwise pin the tile red permanently (the same exclusion the
`NodeDiskPressure` alert uses; `QbtStoreExhausted` covers it at 98%).

## Rack touchscreen kiosk

The DeskPi 7.84" panel hangs off **k3s-node-02** HDMI-A-3 — the only HDMI port in
the cluster. `ansible/kiosk.yaml` provisions cage (a single-app Wayland compositor)
running Epiphany against the Rack Kiosk dashboard, as a sandboxed systemd unit that
cannot disturb the k3s workloads sharing the node:

```bash
ansible-playbook -i ansible/inventory.ini ansible/kiosk.yaml
```

Two choices in that unit exist because of specific failures, and reverting either
breaks the kiosk:

- **No `TTYPath` / `StandardInput=tty` / `PAMName=login`.** Grabbing a VT is the
  logind route to a seat; this box runs seatd instead, and the VT grab fails as a
  non-root user — `Failed to set up standard input: Operation not permitted`,
  exit `208/STDIN`, in a 5s restart loop. seatd supplies DRM master and input with
  no controlling terminal. `LIBSEAT_BACKEND=seatd` skips libseat's logind probe.
- **Epiphany, not Chromium.** Ubuntu's `chromium`/`chromium-browser` packages are
  transitional shims for the snap, which lands in `/snap/bin` — absent from
  systemd's default `PATH` — and snapd's `home` interface won't keep a profile in
  this user's `/var/lib/kiosk` home. Keeping Chromium would mean moving the home
  under `/home`, dropping `ProtectHome`, and patching `PATH`. Epiphany is a plain
  `.deb` and needs none of that.
- **Epiphany needs a session bus** (`default-dbus-session-bus`) and there is no
  logind session to supply one, so the session script wraps it in
  `dbus-run-session`.
- **`WEBKIT_DISABLE_COMPOSITING_MODE` / `WEBKIT_DISABLE_DMABUF_RENDERER`** keep
  WebKit off the GPU. That i915 is also Plex's transcode device, and a static
  dashboard has no need to compete for render contexts on it.

### The three things `--application-mode` requires

Chromeless rendering is all-or-nothing, and Epiphany degrades **silently** to a
normal window with an address bar if any one of these is missing:

1. The profile directory is named exactly `org.gnome.Epiphany.WebApp_<id>`.
2. It contains a `.app` marker file.
3. A matching desktop entry exists at
   `~/.local/share/xdg-desktop-portal/applications/org.gnome.Epiphany.WebApp_<id>.desktop`,
   which Epiphany resolves through the portal.

(1) and (2) are enforced in `ephy-web-app-utils.c`; (3) surfaces only as
`Required desktop file ... not available` in `journalctl -u kiosk`. All three are
derived from `kiosk_app_id` in the playbook so they cannot drift apart.

Even with all three satisfied, the web-app window still draws a **title bar**
(distinct from the address bar). Nothing in Epiphany turns it off: the lockdown
schema has no key for it, and the `state` schema exposes only `is-maximized`, not
`is-fullscreen` — fullscreen is the one mode where Epiphany hides it by itself.
`cage -d` requests server-side decorations, which GTK4 ignores on Wayland. So the
bar is collapsed with `ansible/kiosk/files/gtk.css`, deployed to
`/var/lib/kiosk/.config/gtk-4.0/gtk.css`.

If the panel shows a bare Ubuntu console instead of the dashboard, cage isn't
running — nothing is holding the display, so tty1 shows through. Check
`journalctl -u kiosk -n 30` on k3s-node-02.

Grafana has `auth.anonymous` enabled with the **Viewer** role — the panel has no
keyboard, so an unattended browser cannot complete a login. Grafana is reachable
only over split-DNS and Tailscale, never publicly. Setting `enabled: false` in
`grafana/values.yaml` restores the login requirement and blanks the kiosk.

To point the panel at something else, change `kiosk_url` in `ansible/kiosk.yaml`
and re-run the play.

### Overnight blanking

The panel powers off 22:00–06:00 local time, driven by `kiosk-display@off.timer`
and `kiosk-display@on.timer` around a shared `kiosk-display@.service`. Times come
from `kiosk_wake_at` / `kiosk_blank_hours` in the playbook.

Two things make this work that aren't obvious:

- **Every `OnCalendar` carries an explicit `Europe/Stockholm` suffix**, so the
  times are pinned to local wall-clock regardless of the node's own timezone —
  they kept working unchanged when the nodes moved off `Etc/UTC`. Keep the suffix
  on any new timer rather than leaning on the node zone. Verify a change with
  `systemd-analyze calendar "*-*-* 22:00:00 Europe/Stockholm"`.
- **The off timer re-fires hourly** through the window rather than once at 22:00.
  `kiosk.service` has `Restart=always`, and a fresh cage session comes up with the
  output powered on — hourly means the panel self-corrects within the hour instead
  of staying lit until morning.

The panel only responds to touch-wake inside the ON window; a scheduled blank stays
blanked. To override manually:

```bash
ssh k3s-node-02 sudo systemctl start kiosk-display@on    # or @off
```

The custom `homelab-kiosk` app is no longer displayed on the panel but remains
deployed at [`kiosk.m6o.dev`](https://kiosk.m6o.dev); it is currently unmaintained.
