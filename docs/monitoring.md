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

Sized for the DeskPi 7.84" panel (1280×400) on k3s-node-01 — see below. Two rows of
five grid units is the whole budget, so **new panels have to replace existing ones**
rather than be appended, or they fall below the fold. No legends or axes: it is read
from across the room, and the threshold colours carry the meaning.

`/mnt/r0` is excluded from the "fullest disk" tile because it runs near-full by
design and would otherwise pin the tile red permanently (the same exclusion the
`NodeDiskPressure` alert uses; `QbtStoreExhausted` covers it at 98%).

## Rack touchscreen kiosk

The DeskPi 7.84" panel hangs off **k3s-node-01** DP-2. `ansible/kiosk.yaml`
provisions sway running Epiphany against the Rack Kiosk dashboard, as a sandboxed
systemd unit that cannot disturb the k3s workloads sharing the node:

```bash
ansible-playbook -i ansible/inventory.ini ansible/kiosk.yaml
```

### Why these pieces

- **sway, not cage.** cage is the natural fit for a single-app kiosk, but cage
  0.2.1 aborts whenever an input device is present: it sizes the toplevel with
  `wlr_xdg_toplevel_set_size()` before the client's initial commit, which
  wlroots 0.19 asserts on (`surface->initialized`), yielding a 7s crash loop. Not
  a packaging mismatch — 0.2.1 is the release that tracks wlroots 0.19 — and no
  cage setting avoids that path. sway links the same libwlroots and needs six
  lines of config to do the same job.
- **`sway -c`**, so `/etc/sway/config` is never read: `sway.conf` is the entire
  configuration and the kiosk has no default keybindings.
- **`swaymsg exit` ends the session script.** sway does not exit when its client
  does, so without it a dead browser leaves a black screen with the unit still
  active and `Restart=always` never fires.
- **No `TTYPath` / `StandardInput=tty` / `PAMName=login`.** Claiming a VT is the
  logind route to a seat and fails as a non-root user (`Operation not permitted`,
  exit `208/STDIN`). seatd supplies DRM master and input with no controlling
  terminal; `LIBSEAT_BACKEND=seatd` skips libseat's logind probe.
- **Epiphany, not Chromium.** Ubuntu's `chromium` packages are shims for the
  snap, which lands in `/snap/bin` — outside systemd's default `PATH` — and
  snapd's `home` interface won't keep a profile in `/var/lib/kiosk`.
- **`dbus-run-session`**, because Epiphany requires a session bus and there is no
  logind session to supply one.
- **`WEBKIT_DISABLE_COMPOSITING_MODE` / `WEBKIT_DISABLE_DMABUF_RENDERER`** keep
  WebKit off the GPU; software compositing is free at 1280×400 and holds no
  render contexts on a node running cluster workloads.
- **`ask-for-default=false`** via a GSettings override in
  `/usr/share/glib-2.0/schemas/`, compiled by the playbook. Otherwise Epiphany
  opens a "make this your default browser?" dialog over the dashboard.
  Overriding the shipped default rather than per-user dconf means it survives a
  wiped profile.

### `--kiosk-mode` must be the only mode flag

`--kiosk-mode` removes the browser chrome: it hides the header bar
(`gtk_widget_set_visible (window->header_bar, FALSE)`) and disables the context
menu, so a long press can't summon one. `ephy-main.c` picks the shell mode from
an if/else-if chain:

```c
} else if (application_mode) { mode = EPHY_EMBED_SHELL_MODE_APPLICATION;
} else if (profile_directory) { mode = EPHY_EMBED_SHELL_MODE_STANDALONE;
} else if (kiosk_mode)       { mode = EPHY_EMBED_SHELL_MODE_KIOSK;
```

`kiosk_mode` is last, so `--application-mode` or `--profile` alongside it
silently wins and the chrome returns, with nothing logged. `--profile` is
unnecessary regardless: `HOME` is `/var/lib/kiosk`, so the profile lands in
`/var/lib/kiosk/.config/epiphany` — delete that to reset a wedged session.

The option is version-gated: absent in Epiphany 46.x (Ubuntu 24.04), present in
49.x (26.04). Check `epiphany --help` before moving the panel to an older node.

### Touch input

The digitizer is a plain USB HID device (`wch.cn TouchScreen`), so the kernel
binds `usbhid` at plug-in. No calibration and no touch-to-output mapping, since
sway drives a single output.

Two settings are easy to get silently wrong, both producing the same symptom — a
correctly rendered dashboard that ignores every tap:

- **Don't set `WLR_BACKENDS`.** Naming any backend replaces wlroots'
  autodetection rather than narrowing it, so `drm` alone brings up the display
  with zero input devices and logs no error. Autodetection picks DRM + libinput.
- **`DeviceAllow` needs `char-input`, not `/dev/input`.** A `DeviceAllow` naming
  a directory is accepted then ignored, while still flipping `DevicePolicy=auto`
  into closed. Use the `/proc/devices` subsystem names.

Touch feeds `swayidle`, which wakes the panel from the 15-minute idle blank —
only inside the ON window; a scheduled overnight blank ignores touch.

```bash
ssh k3s-node-01 'grep -A4 -i touch /proc/bus/input/devices'       # kernel
ssh k3s-node-01 'sudo journalctl -u kiosk -b | grep -i libinput'  # compositor
```

If the panel shows a bare Ubuntu console, sway isn't running — nothing holds the
display, so tty1 shows through. Check `journalctl -u kiosk -n 30`.

Grafana has `auth.anonymous` enabled with the **Viewer** role: the panel has no
keyboard, so an unattended browser cannot complete a login. Grafana is reachable
only over split-DNS and Tailscale. Setting `enabled: false` in
`grafana/values.yaml` restores the login requirement and blanks the kiosk.

To point the panel at something else, change `kiosk_url` in `ansible/kiosk.yaml`
and re-run the play.

### Overnight blanking

The panel powers off 22:00–06:00 local time, driven by `kiosk-display@off.timer`
and `kiosk-display@on.timer` around a shared `kiosk-display@.service`. Times come
from `kiosk_wake_at` / `kiosk_blank_hours` in the playbook.

Two things make this work that aren't obvious:

- **Every `OnCalendar` carries an explicit `Europe/Stockholm` suffix**, pinning
  the times to local wall-clock regardless of the node's own timezone. Keep the
  suffix on any new timer rather than leaning on the node zone; verify with
  `systemd-analyze calendar "*-*-* 22:00:00 Europe/Stockholm"`.
- **The off timer re-fires hourly** through the window rather than once at 22:00.
  `kiosk.service` has `Restart=always` and a fresh sway session comes up with the
  output powered on, so hourly means the panel self-corrects within the hour
  instead of staying lit until morning.

The panel only responds to touch-wake inside the ON window; a scheduled blank stays
blanked. To override manually:

```bash
ssh k3s-node-01 sudo systemctl start kiosk-display@on    # or @off
```

The custom `homelab-kiosk` app is unmaintained and unrelated to this panel; it
remains deployed at [`kiosk.m6o.dev`](https://kiosk.m6o.dev).
