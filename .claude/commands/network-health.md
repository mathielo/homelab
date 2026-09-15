---
description: Health sweep of the UniFi network (topology drift, mesh backhaul, AP airtime, wired path, consoles/firmware, WAN, events) — never changes network config (an RF scan is the one permitted device action); may apply its own skill-feedback edits to this file
argument-hint: "[event window, e.g. 24h, 7d — default 24h]"
allowed-tools: mcp__plugin_unifi-network_unifi-network__unifi_execute, mcp__plugin_unifi-network_unifi-network__unifi_tool_index, mcp__plugin_unifi-network_unifi-network__unifi_batch, mcp__plugin_unifi-network_unifi-network__unifi_batch_status, mcp__plugin_unifi-protect_unifi-protect__protect_execute, mcp__plugin_unifi-protect_unifi-protect__protect_tool_index, Bash(ssh:*), Bash(kubectl get:*), Bash(kubectl exec:*), Bash(ping:*), Bash(git status:*), Bash(git diff:*), Bash(jq:*), Bash(python3:*), Bash(grep:*), Bash(sed:*), Bash(awk:*), Bash(echo:*), Bash(printf:*), Bash(date:*), Bash(sort:*), Bash(uniq:*), Bash(head:*), Bash(tail:*), Bash(cut:*), Bash(wc:*), Bash(for:*), Read, Edit
---

Run an on-demand health check of the UniFi network and give me a structured report.
Event scan window: `$1` (default `24h` if empty).

**Requires both UniFi MCP servers** (`unifi-network`, `unifi-protect`). If either is not
connected, say so and stop — SSH alone cannot answer the topology and radio questions
this check is built on. Both run in lazy mode: reach domain tools through
`unifi_execute` / `protect_execute`, and `unifi_tool_index` to find a name.

**The network's configuration is strictly read-only.** Per the repo's MCP Access Policy,
no writes to UniFi through any path: no reboot/provision/adopt/upgrade/rename/locate/
block/forget, no config change on a console over SSH. SSH is for reading counters and
versions. Propose every change as something the user applies in the UI or as code.

The one exception is **`unifi_trigger_rf_scan`** (§3b): it is gated behind a confirmation
because it acts on a device, but it alters no configuration and only refreshes a
measurement. Requiring confirmation is therefore not the test of what this check may
call — *changing the network* is.

The one thing this check may write is **this file** — the §9 skill-feedback edits,
applied when the working tree is clean and proposed as a diff when it is not. Never
`git add`/`commit`/`push`.

**Never put full MACs, the WAN IP, or client MACs in the report file or in this
file.** AP MACs are the BSSIDs beacons broadcast, which wardriving databases index
against physical coordinates; the repo is public. Suffixes are enough to match
runtime output — the same rule [`docs/wifi-mesh.md`](../../docs/wifi-mesh.md)
already follows. In the on-screen report they are fine.

Run the checks below (batch independent calls in parallel), then **interpret** the
results. Apply judgment: separate real problems from the known-benign noise this
network generates in volume. The standing goal is a warning-free network.

## 0. Resolve the devices (never hardcode addresses)

Every UniFi device except the gateway, NVR and NAS is on VLAN 1 by DHCP, so **IPs
change and the MAC suffix is the stable identifier**. Start here; every later section
uses this mapping.

```
unifi_execute unifi_list_devices {"include_details": true, "summary": true}
```

Take `mac`, `ip`, `name`, `status`, `uptime`, `firmware`, `upgradable`, `uplink`,
`load_avg_1`, `mem_pct` from that one call. Resolve the AP address for the SSH
sections from it — not from a literal in this file.

The UniFi SSH user for VLAN-1 devices is in
[`.config/ssh.config`](../../.config/ssh.config) (the `Host 10.10.1.*` block); APs and
UDBs are not reachable from the workstation VLAN, so jump: `ssh -J UGCMax
"$USER@$IP"`. The gateway, NVR and NAS have their own aliases (`UGCMax`, `UNVR`,
`UNAS`) and are reachable directly.

## 1. Topology drift (current vs baseline)

No cross-room cable runs are possible, so the _shape_ of the network is fixed even
though individual cables move. The authoritative baseline is the Topology section of
[`docs/wifi-mesh.md`](../../docs/wifi-mesh.md) — mesh parents, bands and channels — with
the device inventory in [`docs/hardware.md`](../../docs/hardware.md). Diff reality
against those.

**Which port a device sits on is not part of the baseline.** Cables get moved; a device
appearing on a different port is not a finding and must not be reported as drift. What
matters is that the device is still _there_, still on the expected bridge, and still
linked at a sane speed.

Check and report each deviation:

- **Mesh parent** of each UDB (`uplink.uplink_device`). A UDB that re-parented, or
  fell back to a different band, is a 🔴 finding — it is also the single most likely
  cause of a "everything got slow" report.
- **Radio channels and widths** on both APs (§3). The assignment is validated, not
  incidental; an `AP_CHANGED_CHANNELS` event (§7) is how it moves on its own.
- **Wired spine** — both APs still wired to the switch, and the switch's uplink to the
  gateway still up at 2.5 GbE. Port _numbers_ don't matter; the links being up does.
- **Bridge membership** — the set of devices behind each UDB, not their port order. A
  homelab device that vanished from its bridge is a 🔴 finding.
- **Adopted device set** — a UniFi device that appeared or disappeared.

> ⚪ **Scope.** Equipment unrelated to the homelab is connected from time to time for
> other work. It is not part of this setup, is not documented, and is **out of scope**:
> never report it as drift, as an unknown device, or as a rogue. Network-wide _effects_
> stay in scope whatever their source — a rogue DHCP server or a forwarding loop is a
> finding no matter which device caused it (§7).

> ⚪ **AirWire (`UAPEA07`) is expected-offline** — powered on only for occasional
> ad-hoc use. Never flag it. **Any other offline adopted device is a 🔴 finding.**

**A drift that turns out to be intentional is a doc bug, not a finding.** Correct
`docs/wifi-mesh.md` or `docs/hardware.md` in the same run and show the diff — the repo
is the source of truth and a stale baseline makes every future run of this check
lie. Never trust the doc over the live config.

## 2. Mesh backhaul — the headline section

`UDB Homelab` carries the entire rack (all k3s nodes, the NAS, both a Pi-hole and Home
Assistant, and the workstation) behind **one wireless link** to the U7 Pro XG. That
link is the first suspect for any slowness anywhere, and it is the thing this check
exists to measure.

### 2a. Is the link the expected one?

```
ssh -J UGCMax "$USER@$XG" 'wlanconfig mld0 list sta; wlanconfig vwireap11 list sta'
```

MLO is off (§9 standing conditions), so `mld0` answers `Error received: -19` — that error
is the confirmation it is still off — and `UDB Homelab` is a plain station on `vwireap11`:
`CHAN 37`, `IEEE80211_MODE_11BEA_EHT320`. Read `TXRATE`/`RXRATE`, `RSSI` and `ASSOCTIME`
against the UDB's `/proc/uptime`; an `ASSOCTIME` far shorter than uptime means the link
re-associated — correlate with §7.

**If `mld0` lists stations, MLO is back on** — a re-open trigger — and the rest of this
subsection applies: `UDB Homelab` then shows **two links in one MLD** (5 GHz EHT80 and
6 GHz EHT320); read `MLO` and `Num Partner links` as well.

Four traps make a healthy link look broken; they are documented in
[`docs/wifi-mesh.md`](../../docs/wifi-mesh.md#four-traps). Read them before judging
this section. The one that bites _this_ check hardest is the fourth: **only the sum
across both MLO links is meaningful.** Reading the per-link split as a band assignment
produces a confident, wrong story about which radio is loaded — §3's per-radio airtime
is the measurement that answers that.

**An MLD can associate both links and run everything over one of them, and which one it
picks is not stable across re-associations.** Onto the 320 MHz link that is benign; onto
the 80 MHz link it is a silent 2× capacity loss. Read the split from **per-radio airtime
at two load points** — once loaded, once light. A link that stays at its floor in _both_
is idle, not merely unlucky in one sample. Then normalise (§3): **~4.4 Mbit/s per
%self-CU means the traffic is on 80 MHz, ~8–9 means 320 MHz.** That one number names the
band outright and is the fastest way to catch this.

Two corroborating signals, both free in the same pass:

- **PHY-rate stability across samples.** The strained link's `TXRATE`/`RXRATE` sag under
  load (observed 864 → 720 → 600 M on EHT80) while the idle link never moves.
- **Per-link error counters on the child** — fields 3–4 of `/proc/net/dev` for
  `vwiresta0` / `vwiresta1`. Errors climbing on one link and flat on the other is the
  split, independent of the byte counters that lie about it.

### 2b. Throughput, measured correctly

Sample the parent AP's mesh VAPs and the child's own NIC over the **same** window, so
the two are comparable:

```
XG=<resolved IP>; U=<unifi ssh user>
( ssh -J UGCMax "$U@$XG" 'grep -E "vwireap10:|vwireap11:" /proc/net/dev; sleep 30;
    grep -E "vwireap10:|vwireap11:" /proc/net/dev' > /tmp/xg.txt ) &
( ssh k3s-node-02 'grep eno1: /proc/net/dev; sleep 30; grep eno1: /proc/net/dev' > /tmp/n02.txt ) &
wait
```

`vwireap10` is the 5 GHz mesh VAP and `vwireap11` the 6 GHz one; the AP's **tx is
downstream** (AP → UDB). Sum both VAPs per direction, divide by the interval, and
compare against the child NIC.

The UDB's own view is worth a second read when the AP's numbers look odd — it names
the links `vwiresta0` / `vwiresta1` and carries the mesh error counters:

```
ssh -J UGCMax "$U@$UDB_HOMELAB" 'cat /proc/loadavg; grep -E "eth[01]:|vwiresta" /proc/net/dev'
```

**Judge by divergence, not by absolute throughput.** If the mesh total and the child
NIC agree within a few percent, the mesh is delivering exactly what is being asked of
it and is _not_ the bottleneck, however small the number. A real ceiling shows up as
the mesh figure pinned flat while demand runs above it. 🟡 above 8% divergence,
🔴 above 15% sustained.

**Divergence is signed, and only one direction is a fault.** k3s-node-02 is one of
several devices on the bridge, so **mesh > child NIC is normal** — the surplus is the
NAS, the other nodes and the workstation, and it grows with how busy they are. Only
**mesh < child NIC** means frames are being lost or queued between the two, and only
that direction earns a 🟡/🔴. Apply the thresholds to the shortfall, never to the
surplus.

### 2c. Establish the offered load before calling anything a bottleneck

**A low throughput reading with low divergence means the network is idle, not
choked.** This is the single easiest way to misread this section, so measure demand
in the same window rather than inferring it:

```
for p in $(kubectl get pods -n media -o name | grep -oP 'qbt-[a-z]+-[a-z0-9-]+'); do
  echo -n "$(echo $p | grep -oP 'qbt-[a-z]+'): "
  kubectl exec -n media $p -c main -- wget -qO- localhost:8080/api/v2/transfer/info; echo
done
```

`dl_info_speed` / `up_info_speed` are bytes/s (the localhost auth bypass means no
credentials are needed). Add SABnzbd and any active Plex session for the full picture.

**The health baseline is the loaded case, not the idle one:** all `qbt-*` instances
downloading at their combined ceiling (~80 MB/s, i.e. ~640 Mbit/s — the figure is in
**bytes**, and reading it as bits understates the target by 8x) _while_ Plex streams and
the workstation is in normal use, with none of the three visibly degraded. That is the
state this network holds most of the time and the state a run should try to assess.
If the offered load is far below it, say so plainly and mark the section
**⚪ inconclusive — network idle**, rather than reporting a clean bill of health the
measurement does not support. Note the known-good ceiling under real load is
663 Mbit/s downstream (`docs/wifi-mesh.md`), so tens of Mbit/s is not a ceiling.

The reverse misreading matters too: ~70–80 MB/s of combined qBittorrent and Plex
traffic is **normal working load**, not a fault. Never propose capping
`dl_rate_limit` to fix slowness.

### 2d. Cross-VLAN hairpin

Traffic that crosses a VLAN between two devices on the same bridge hairpins the radio
twice instead of switching locally (`docs/wifi-mesh.md`). So a workload that _starts_
crossing VLANs — a new service reaching the NAS from VLAN 10, say — is a throughput
finding, not just a routing detail. Check that NAS traffic is still intra-VLAN 50.

## 3. AP radios and airtime

```
unifi_execute unifi_get_device_radio {"mac_address": "<AP mac>"}   # both APs
```

Per radio, record `current_channel`, `ht`, `cu_total`, `cu_self_tx`, `cu_self_rx`,
`num_sta`, `tx_retries`/`tx_packets`, `current_tx_power`.

**`cu_total` alone is misleading — it is the number most likely to cause a false
alarm.** Two derived figures are the real signals:

- **External airtime** = `cu_total − cu_self_tx − cu_self_rx`. Our own useful traffic
  filling a channel is fine; someone else's is not. 🟡 above 20%, 🔴 above 40%.
- **Retry rate** = `tx_retries / tx_packets`. 🟡 above 20%, 🔴 above 30%. The
  known-good loaded baseline is 10.5% on 5 GHz and 15.0% on 6 GHz.
  ⚠️ **The controller's retry counters exclude the mesh VAPs.** Both
  `unifi_get_device_radio` and the raw `vap_table` count client SSIDs only, so a radio
  carrying the whole backhaul reports a few thousand frames (or `0`–`1`), and the ratio
  describes whichever client shares it. For the backhaul, read the mesh VAP on the AP
  twice and divide the deltas:

  ```
  ssh -J UGCMax "$U@$XG" 'apstats -v -i vwireap11 | grep -E "^(Tx Data Packets|Retries) "'
  ```

  Use the controller figures only for client radios, and say "unmeasurable" rather than
  dividing by a near-zero `tx_packets`. Never report 0%.

**Normalise airtime as Mbit/s per %self-CU** — measured mesh throughput (§2b) divided by
`cu_self_tx + cu_self_rx`. This is the number that makes airtime _comparable_: raw CU
says a channel is busy, efficiency says what it is buying. It is also how to size a
proposed change before making it — divide the same traffic by a wider channel's
efficiency to get the CU it would cost there, and how much any one station contributes
by dividing its own measured rate by the figure. Expect roughly **4.4–4.7 Mbit/s per
%CU at 80 MHz** and **8–9 at 320 MHz**. A client station on the same radio adds its own
airtime to self-CU, so the figure reads somewhat low while `num_sta` shows one active. A
band change is worth about a 2× airtime saving, and a station moving tens of kbit/s is
worth nothing measurable however bad its RSSI looks. Do this arithmetic before proposing
to move anything — it separates the levers that matter from the ones that merely feel
productive.

**Band balance is the check that catches the slow-choke.** The 6 GHz radio (ch37 @
320 MHz) is the widest, quietest pipe in the building and the only one the U7 Mesh
cannot contend with.

**The XG's ch36 carries no mesh backhaul.** `UDB Homelab` meshes on 6 GHz only and the
Balcony meshes on the U7 Mesh's ch104, so ch36 is a client radio — phones, laptops and the
Steam Deck roam onto it — and its CU never touches the rack's uplink. The 5 GHz channel
that does carry backhaul is **ch104**, shared by the Balcony's link and most of the flat's
5 GHz clients.

Report both radios' CU side by side and call out the imbalance — 🟡 when MLO is on and
5 GHz CU exceeds 6 GHz CU by more than 25 points under non-trivial load, and **🔴 whenever
the normalised efficiency lands at the narrow band's figure** (~4.4 rather than ~8–9
Mbit/s per %self-CU), whatever raw CU reads. Efficiency catches the collapse at any load;
a CU-gap threshold only catches it at full tilt, which is how the 2026-09-09 run nearly
missed it.

Do **not** try to confirm the split from the mesh VAP byte counters (§2a, trap 4).
Per-radio airtime is an independent measurement and is the one to trust.

**Weak clients on a mesh channel are an airtime tax.** A station at a poor RSSI
transmits at low MCS and holds the channel far longer than its byte count suggests, so
it steals airtime from the backhaul sharing that radio. List the clients on the mesh
channels (the XG's ch37 and the U7 Mesh's ch104) and flag any below **−78 dBm** — worst
when it is something that transmits _continuously_, such as a recording camera. The
lever is moving that device to the other AP or the other band, not touching the mesh:

```
unifi_execute unifi_list_clients {"filter_type": "all", "limit": 60}
```

Read `channel`, `radio` and `signal_dbm`; cross-check the recorders against §8.

Also check, from `unifi_list_devices`: the U7 Mesh's 2.4 GHz radio is on **auto**, so
its `current_channel` moves. It must stay non-overlapping with the XG's ch11 — 1 or 6
are the only valid landings. Anything else is a 🟡 finding.

**Region SE constrains every RF option** — 5 GHz non-DFS is only ch36–48, there is no
UNII-3, and the XG's ch36 @ 80 MHz already spans 36–48. Never propose a 5 GHz channel
change for the XG or ch116. See the doc's Gotchas.

### 3b. Spectrum scan — is the congestion ours or someone else's?

Airtime tells you a channel is busy; only a spectrum scan tells you **who is filling
it**, and that decides whether a channel change can help at all.

```
unifi_execute unifi_get_rf_scan_results {"ap_mac": "<AP mac>"}   # both APs
```

This is **read-only and safe to run every time** — it returns the _last_ scan the AP
performed, per band, as a `spectrum_table` of `channel`, `interference` (dBm),
`utilization` (%) and `other_bss_count`.

**`unifi_trigger_rf_scan` is allowed**, with the `confirm: true` the tool requires. It
is classed as a mutation (`readOnlyHint: false`, `permission_action: update`,
`permission_category: devices`) because it is an action *on a device*, not because it
writes configuration — `destructiveHint: false`, `idempotentHint: true`, and it changes
no setting. The only thing it produces is a fresh `spectrum_table`.

Two things decide whether to fire one:

- **The trigger is per-AP, not per-radio.** There is no band parameter, so scanning the
  U7 Pro XG scans all three of its radios — including the 6 GHz one carrying the whole
  rack's uplink. You cannot scan ch36 alone.
- **It does not drop the mesh child on this hardware.** Verified on 2026-09-09 and
  2026-09-15: a full three-band XG scan finishes in ~70 s, and `UDB Homelab`'s
  `ASSOCTIME` runs straight through it. The tool's own description allows for this: some
  APs have a dedicated scanning radio, and this one behaves as though it does.

Poll `unifi_get_rf_scan_results` until every radio's `spectrum_table_time` is newer than
the trigger — usually within two minutes, allow ten. **The cached table is the
controller's nightly scan at ~01:00 UTC**, so a daytime read is hours old by
construction. Two situations still call for restraint: don't trigger a scan *while*
measuring a live throughput fault — it perturbs the airtime you are trying to read — and
don't fire one when the cached table is already fresh enough to answer the question.
Otherwise, a stale table is a reason to scan, not a reason to hedge.

Reading it correctly:

- **`interference` is dBm, so less-negative is worse.** `-96` is the noise floor —
  nothing is there. `-30` is a strong emitter. Do not sort it as if bigger were better.
- **`utilization` is airtime on that channel**, ours included.
- The two together are the whole point: **high utilization with interference at the
  noise floor means the channel is full of our own traffic, and no channel change will
  help** — on 6 GHz that includes any secondary 20 MHz row inside ch37's own 320 MHz
  block, which can read up to 100% at `-96`. The only levers are moving load off that
  radio or making it more efficient.
  High utilization _with_ a strong interferer is the opposite case, and there a channel
  move is the fix.
- An AP scanning the band it is _operating_ in will report its own transmissions as
  interference. Cross-read the two APs: what one AP sees as a strong signal on a
  channel is usually the other AP, not a neighbour.
- Report the scan's **age** from each scan's own `spectrum_table_time`, **not** from the
  top-level `spectrum_scan_timestamp` — that one lags and has been observed hours stale
  while the per-radio tables were minutes old. A day-old scan describes yesterday's RF;
  never conclude "the band is clear" from a stale table when live airtime disagrees —
  trigger a fresh one instead, per the note above.
- **`utilization` at widths above 20 MHz is an arithmetic mean of the constituent
  20 MHz channels, not a prediction.** A busy primary surrounded by empty secondaries
  reads low and flattering: 92% at 20 MHz becomes 47 / 25 / 11% at 40 / 80 / 160 simply
  by averaging in the idle neighbours. Widening does **not** move a channel to that
  number — the traffic spreads rather than disappearing. Judge a candidate block by its
  **per-20 MHz rows**, and size the actual gain from the PHY-rate doubling (§3's
  Mbit/s per %CU), never from the wide-width utilisation figure.

Cross-check `ROGUE_AP_DETECTED*` in §7 against a scan showing a new strong emitter.

## 4. Wired path

```
unifi_execute unifi_get_port_stats {"device_mac": "<switch mac>"}
unifi_execute unifi_get_device_details {"mac_address": "<udb mac>", "summary": true, "include": "basic,ports,uplink,stats"}
```

For every up port: `speed`, `full_duplex`, `rx_errors`, `tx_errors`, `rx_dropped`,
`tx_dropped`, and PoE draw against `max_poe_power`.

- **A link negotiated below what both ends can do** is worth one 🟡 line — a 2.5 GbE
  device at 1 GbE is usually a cable, and nothing surfaces it until someone looks.
  Several devices here legitimately link slower than their port allows because their
  own NIC is the limit, so report the observation and let the user judge; do not diff
  against a stored table of expected speeds. A `NEGOTIATED_LOW_UPLINK_PORT_SPEED`
  event (§7) is the controller reaching the same conclusion.
  Whether the endpoint's NIC is the limit is one read on that host:
  `ethtool <iface> | grep -A4 'Supported link modes'` (the UNAS-4's sysfs `speed` file
  errors; `ethtool` works).
- **Error and drop counters are lifetime totals** — a large absolute number on a port
  with months of uptime says nothing. Sample twice ~60 s apart and report the _rate_;
  only a counter that is still moving is a finding.
- **PoE** — 🟡 within 10% of `max_poe_power`, and check for `POE_BUDGET_EXCEEDED` in §7.

## 5. Consoles and firmware

Three separate UniFi OS consoles run here and **the Network application only knows
about one of them.** `upgradable` from `unifi_list_devices` covers Network-adopted
devices (gateway, switch, APs, UDBs); the UNVR-I and UNAS-4 are independent consoles
that are invisible to it and must be read over SSH:

```
for h in UGCMax UNVR UNAS; do
  printf '%-8s ' "$h"
  ssh -o ConnectTimeout=10 $h 'ubnt-device-info summary 2>/dev/null | grep -i firmware || cat /usr/lib/version'
done
```

Report all three UniFi OS versions plus the Network application version
(`unifi_get_system_info`) and every device firmware. Flag any device with
`upgradable: true`, and flag a console that trails another console on the **same
platform** — the UNVR-I and UNAS-4 share the rtd1619 SoC and track the same build
stream, so a version gap between them is a real pending update even when nothing
advertises it.

Per the repo's versioning policy, updates are applied by the user, never by this
check. Report the versions and the gap; do not upgrade anything.

## 6. Gateway, WAN and ISP

```
unifi_execute unifi_get_network_health
unifi_execute unifi_get_system_info
unifi_execute unifi_get_gateway_stats {"duration": "hourly"}
```

- **Subsystem health** — `wan`, `www`, `lan`, `wlan`, `vpn`. ⚠️ `lan`/`wlan` sit at
  `error`/`warning` whenever a device is offline, and AirWire is _always_ offline by
  design. Before treating a non-`ok` subsystem as a finding, check whether the offline
  set is exactly `{AirWire}`; if it is, the subsystem status is ⚪ by-design. If any
  other device is offline, or the subsystems are non-`ok` with everything online, it
  is a real finding.
- **Gateway load** — `mem_pct` and `load_avg_1` from the device list; judge CPU from the
  hourly `cpu` in `unifi_get_gateway_stats`, because the device list's `cpu_usage` is a
  point sample that bursts past 80% inside hours averaging 20–40%. 🟡 CPU above 70%
  sustained or memory above 85%.
- **WAN** — `wan1_up`, the negotiated WAN port speed, and the rx/tx rates. The WAN
  port is 1 GbE, so it, not the mesh, is the ceiling for internet-sourced traffic.
- **ISP quality** — `ISP_PACKET_LOSS`, `ISP_HIGH_LATENCY`, `NETWORK_WAN_FAILED*`,
  `NETWORK_FAILED_OVER_TO_BACKUP_*` in §7. There is no secondary WAN, so a WAN failure
  is a full outage.
- **Latency and bufferbloat** — a loaded uplink that stays responsive is the whole
  point of the user's baseline, so measure it _while_ §2c's load is running:

  ```
  ping -c 20 -i 0.2 10.10.1.1        # gateway: isolates LAN/mesh from WAN
  ping -c 20 -i 0.2 9.9.9.9          # WAN path
  ```

  Report min/avg/max/mdev for both. 🟡 when the gateway's max exceeds 50 ms or its
  mdev exceeds 10 ms — that is queueing on the mesh, and it is what "everything feels
  slow" actually is. A WAN max far above the gateway max under load is bufferbloat on
  the uplink, for which Smart Queues is the lever.

## 7. Events and alarms

```
unifi_execute unifi_list_alarms
unifi_execute unifi_list_events {"within_hours": <window>, "limit": 100, "severities": ["HIGH", "VERY_HIGH"]}
unifi_execute unifi_list_events {"within_hours": <window>, "limit": 100, "categories": ["UNIFI_DEVICES", "UNIFI_ETHERNET_PORTS", "INTERNET_AND_WAN", "POWER", "SOFTWARE_UPDATES", "VPN", "AUDIT", "UNKNOWN"]}
unifi_execute unifi_list_events {"within_hours": <window>, "limit": 200}
```

Any **active alarm** is a finding by definition and goes straight to §9.

**The unfiltered feed covers hours, not the window.** `SECURITY` (the firewall blocks on
the accept-list below) and `CLIENT_DEVICES` (connect/roam churn) fill a 200-event page in
about half a day. The two filtered calls leave both out and return the whole window in a
few KB — they are what answers "did X happen". For the table's keys that can land in
those two
(`ROGUE_*`, `NETWORK_LOOP_*`, `CLIENT_LINK_FLAP_WIRED`, `CLIENT_WIFI_SCORE_*`), run one
exact `event_type` query each through `unifi_batch`; an empty result is trustworthy
(`DEVICE_UNREACHABLE` returns its event as a positive control). An invalid `event_type`
returns the full enum in the error.

The unfiltered page is for ranking churn only. ⚠️ **`limit: 200` overflows the tool
output budget** — the result is written to a file; aggregate from it rather than
re-querying:

```
grep -oP '"key":\s*"\K[A-Z_0-9]+' "$F" | sort | uniq -c | sort -rn
```

Report the span those 200 actually cover (`"time"` is epoch ms), not the requested
window, and never conclude "no X" from it.

`unifi_get_anomalies` is a second, independent feed worth one call — it is where
`AP_HIGH_UTILISATION`, `USER_DNS_TIMEOUT` and `USER_HIGH_TCP_LATENCY` land, and a burst of
the latter two on unrelated clients is usually airtime starvation rather than a DNS fault.
Two caveats, both measured on 2026-09-09: **`duration` is ignored** — `weekly` and
`monthly` returned byte-identical 24 h payloads, so there is no anomaly history beyond a
day; and **`AP_HIGH_UTILISATION` did not fire for the XG's 5 GHz radio during 24 h at 95%
`cu_total`**, then fired within minutes once 6 GHz reached 78%. Treat its silence as
meaningless and its presence as a hint, never as the utilisation check itself — §3 is that.

Do not read the raw feed and eyeball it: it is dominated by connect/disconnect churn.
**Aggregate by `key`, count, and rank** — a count is the finding, a single line
almost never is. Then check these explicitly, because they are quiet and important:

| Event key                                                        | Why it matters here                                                                 |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `AP_CHANGED_CHANNELS`, `AP_CHANGED_CHANNELS_RADIO_AI`            | Moves the validated channel plan on its own; §1 drift and §3 collisions follow      |
| `AP_DETECTED_RADAR`, `AP_DETECTED_RADAR_V2`                      | The U7 Mesh's ch104 is DFS — a detection takes it and the Balcony off-air 30 min    |
| `DEVICE_UNREACHABLE*`, `DEVICE_RECONNECTED*`, `DEVICE_STOP_MESH` | A mesh child dropping takes every wired device behind it with it                    |
| `LOG_SWITCH_PORT_LINK_FLAP`, `CLIENT_LINK_FLAP_WIRED`            | Cabling; on the UDB it interrupts the whole rack's NFS                              |
| `NEGOTIATED_LOW_UPLINK_PORT_SPEED`                               | The silent half-speed link §4 hunts for                                             |
| `ROGUE_DHCP_SERVER_DETECTED`, `NETWORK_LOOP_DETECTED_BY_*`       | In scope whatever caused them — both break the network for every device on it       |
| `ISP_PACKET_LOSS*`, `ISP_HIGH_LATENCY*`, `NETWORK_WAN_FAILED*`   | Upstream, and the only WAN there is                                                 |
| `POE_BUDGET_EXCEEDED*`, `POE_PORT_BUDGET_EXCEEDED*`              | Two APs and two Pi-class devices draw PoE from one switch                           |
| `MAC_TABLE_APPROACHING`, `MAC_TABLE_FULL`, `PORT_*_STORM`        | Forwarding-plane trouble that looks like generic slowness                           |
| `FIRMWARE_UPDATE_AVAILABLE*`, `BULK_FIRMWARE_UPDATE_AVAILABLE`   | Cross-check against §5                                                              |
| `AFC_*`                                                          | XG 6 GHz is LPI (raw `radio_table`: `afc_done: 0`); an AFC event means it moved     |
| `CLIENT_WIFI_SCORE_HAS_DROPPED*`                                 | The controller's own view of a degrading client                                     |

## 8. Protect subsystem

The cameras are on their own VLAN and their own console, but they share the RF and the
wired path, so a Protect fault is often an RF fault wearing a costume.

```
protect_execute protect_list_cameras
```

Flag any camera not `CONNECTED`, and note which are wireless — a wireless camera
degrading is an early symptom of the same airtime pressure §3 measures. Cross-check
the NVR's own console version in §5.

**Every camera belongs on VLAN 20.** Wireless cameras join the shared SSID and reach
Protect only through a per-client **Virtual Network Override**; a camera without one
lands on VLAN 10 Trusted, outside the Protect segment and with Trusted's reach into
Servers, and its stream is routed through the gateway to the NVR. Check that every
camera's `ip` in the §3 client list is `10.10.20.x` — anything else is a 🔧: set that
client's override to `VLAN 20 - Protect`.

## 9. Warnings sweep & assessment (the headline output)

Aggregate **every** warning from §1–§8 — drift, mesh divergence, airtime and retry
breaches, port errors still incrementing, firmware gaps, non-`ok` subsystems, ranked
event counts, active alarms — and assess each:

`Source | Warning | Frequency | Assessment`

Assessment is **🔧 fixable** (give the concrete change for the user to apply),
**✅ accept** (known-benign; say why), or **⚪ standing** (a real condition already
accepted with an exit trigger — one summary line, not a row).

Fill **Frequency** from counts, not impressions. **High-volume benign noise is itself
a 🔧 finding**: propose the config change that quiets it rather than growing the
accept-list forever.

**A count is not evidence that something is still happening.** A periodic event that
stopped an hour ago still contributes its whole history to the window's total, so a
raw count will report a fixed problem as ongoing. For every recurring finding, read the
**last occurrence and the interval**, and compare: if more than two intervals have
passed with nothing, it has _stopped_ — report it as resolved, not as a repeat offence.
Never carry a 🔧 forward as "still unfixed" without checking recency first; the user may
have fixed it since the last run, and telling them otherwise is worse than silence.

### Known-benign — drop these before reporting

- **AirWire offline** — expected-offline by design (§1), and the likely sole cause of
  a non-`ok` `lan`/`wlan` subsystem (§6).
- **`UNAS-4 connected to … UDB Homelab Port 8` repeating** — the controller logs this
  tens of times a day, and it is **not** a link flap. The NAS's own NIC disagrees:
  `carrier_changes` on the endpoint stays at 2 (one boot transition) across days
  in which the controller logged dozens of "connects". It is the UDB re-learning an
  aged-out MAC entry, not a physical event. **Verify, don't re-investigate:**
  `ssh UNAS 'cat /sys/class/net/eth0/carrier_changes'` — the count only advances on a
  real transition, and only a rising count is a finding. The same reasoning covers the
  workstation and the Steam Deck dock on their own ports.
- **`homeassistant … blocked from accessing 1.1.1.1 / 1.0.0.1 by Block ext DNS`** —
  **fixed 2026-09-08** by `ha dns options --servers dns://10.10.53.53 --fallback=false`;
  the HA OS DNS plugin was probing its hardcoded Cloudflare fallback every ~600 s, which
  the DNS-leak policy blocked every time. Verify with `ssh homeassistant 'ha dns info'`
  (expect `fallback: false`) before reopening. If these events return, the plugin config
  was reset — re-apply rather than re-investigating.
- **`Dev UGC Max was blocked from accessing 8.8.8.8 / 1.1.1.1 by the Block DoH -
Internal Firewall Policy`** — every ~5 min (~290 a day), the single largest
  contributor to the feed and the reason an unfiltered page covers hours (§7).
  `Dev UGC Max` is out-of-scope dev equipment on the Homelab bridge, and the block is
  the DNS-leak policy working on a device that probes hardcoded DoH resolvers. Not the
  Home Assistant case above (that one was fixed at
  source). Count it and move on; there is nothing to fix on our side.
- **k3s-node-01 shown at `10.10.50.3`** in the controller's client list — that is the
  MetalLB VIP, L2-announced from whichever node currently holds it, so the controller
  attributes it to that node's MAC. Not an addressing fault.
- **The secondary MLO link reporting `STATE 3` with blank `HTCAPS` and `IEs: 00`** —
  association state lives on the primary link. Documented trap 3.
- **Mesh VAP per-link byte counters reading zero in one direction** — the MLO
  accounting artifact, on both the AP and the UDB. Only the sum is real. With MLO off,
  `vwireap10` / `vwiresta0` read zero because no 5 GHz mesh link exists.
- **`AP_HIGH_UTILISATION` on the U7 Pro XG through loaded hours** — fires every 5 min
  while the backhaul is busy. It is ch37's own backhaul airtime, which the standing
  conditions already accept as the cost of the work. It is a finding only when §3 shows
  that radio's external airtime or efficiency breaching.

### Standing accepted conditions

Real conditions knowingly accepted, each with the trigger that ends the acceptance.
Report as one line, but **evaluate every re-open trigger every run** — if one fires it
leaves this table and becomes a 🔴 finding.

| Since      | Condition                                                                                            | Why accepted                                                                                                                                                                                                                                              | Re-open when                                                                                                                                                                                                                 |
| ---------- | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-09-08 | Whole rack + workstation behind one wireless mesh link (`UDB Homelab`)                               | No cable runs are possible in the apartment; this is the architecture, not a defect                                                                                                                                                                       | Mesh falls **short of** the child NIC by more than 8% under load (a surplus never counts — §2b) · mesh downstream stays pinned flat while measured demand exceeds it                                                         |
| 2026-09-09 | **MLO disabled** on the mesh WLAN; `UDB Homelab` runs a single-link 6 GHz backhaul on ch37 @ 320 MHz | With MLO on, the MLD associated both links and ran ~100% of traffic over the 80 MHz link for 8 days — a silent 2× loss. The controller exposes no link-selection control, so disabling MLO is the only deterministic fix. Reported to Ubiquiti 2026-09-09 | MLO is re-enabled (a firmware update restoring defaults would do it) · normalised efficiency drops to ~4.4 Mbit/s per %self-CU, meaning traffic is back on an 80 MHz link · a second mesh child needs MLO for its own uplink |

Baselines for those rows (quote current numbers against them — an accepted condition
still gets measured). **Under load** is the one that counts; the idle figures are kept
only so a quiet run has something to compare against.

| Measured                                     | Mesh down  | Mesh up    | Divergence vs node-02 | Efficiency | ch36 CU (self) | ch37 CU (self) |
| -------------------------------------------- | ---------- | ---------- | --------------------- | ---------- | -------------- | -------------- |
| **Healthy — MLO off, 432 Mbit/s qBt demand** | 515 Mbit/s | 106 Mbit/s | −0.9% down · −1.7% up | **8.51**   | 6 (1)          | **78 (73)**    |
| Fault — MLO on, collapsed onto ch36          | 404 Mbit/s | 33 Mbit/s  | +1.6% down · −4.0% up | **4.43**   | **95 (93)**    | 7 (7)          |
| Reference — 6 GHz single link, 2026-08-28    | 526 Mbit/s | 157 Mbit/s | 0.9% down             | 8.9        | 20             | 82             |

`UDB Homelab` uplink is a **single 6 GHz link** (§2a): ch37 EHT320, −65 to −66 dBm,
1080–1729 Mbps. External airtime on ch37 is 1–5%.

**Efficiency is the row that matters.** 8.5 Mbit/s per %self-CU is a 320 MHz link doing its
job; 4.4 is the same traffic squeezed onto 80 MHz. High CU on ch37 is the cost of the work,
not a ceiling — at 73% self-CU delivering 621 Mbit/s there is headroom to ~850. Latency
improved with the fix even at higher load: gateway RTT **avg 18.3 ms, max 41.5 ms, mdev
8.7 ms** from a station behind the bridge, against **29.4 / 64.2 / 15.7 ms** in the fault
state. Compare against these before calling a latency rise new.

Adding a row here is deliberate: it needs the re-open trigger _and_ the baseline,
otherwise it is not an acceptance, it is a blind spot. Permanent by-design exemptions —
AirWire, out-of-scope equipment — belong in the accept-list above, not here; this table
is only for conditions that are meant to end.

### Where this check stops

Pi-hole HA, the DNS chain and cert/ingress health belong to
[`/cluster-health`](cluster-health.md) §7 and are not repeated here. If a DNS symptom
shows up in this run, name it and point at that check rather than re-deriving it.

## Output

Use 🟢 / 🟡 / 🔴 everywhere state is reported, plus ⚪ for by-design rows that are
deliberately exempt. Use ⚠️ inline when calling out a specific warning in prose.

1. One-line **verdict** (🟢 healthy / 🟡 N warnings / 🔴 issues), with standing
   conditions riding along: `🟢 healthy — 2 standing (mesh SPOF, MLO off)`. It can
   never be 🟢 while an unassessed alarm is active.
2. **Topology map** — the current tree (gateway → switch → APs → mesh children →
   wired clients), with any §1 drift marked. This is the section that makes the rest
   readable; render it even when nothing drifted.
3. **Mesh table** — per direction: measured throughput, child NIC, divergence, link
   state and PHY rates, and **the offered load it was measured under**. If the
   network was idle, say so here, not in a footnote.
4. **Radio table** — one row per radio: `Status | AP | Band | Ch/Width | CU | External | Retries | Stations`.
5. **Wired line** — anything linked slower than both ends support, or any error
   counter still moving; otherwise one line saying neither was found. Don't enumerate
   healthy ports.
6. **Firmware table** — the three consoles, the Network application, and every device,
   with any gap called out.
7. Short **per-area** lines (WAN/ISP, latency, Protect, events) each with a marker.
8. The **Warnings & assessment** table — the focus. For 🔧 items give the concrete
   change and **do not apply it**; the user applies every network change themselves.
9. **Skill feedback** — close every run with what it taught this check: a false
   positive to accept-list, a manual command that should have been a step, a miss a
   section should have caught, a threshold that drifted. "Nothing to change" is valid;
   an empty section every run is not.

   **Most findings do not belong in this file.** A run surfaces plenty worth saying
   and not worth persisting: what a number read today, which incident a burst traced
   to, what got ruled out. That goes in the report. Only write here what **changes how
   a future run behaves** — a check it would otherwise skip, a false positive it would
   re-derive, a threshold, a failure mode with a named fix. Specifically keep out this
   run's measurements (except a standing condition's baseline, which exists to be
   compared against), narrated history, and decisions still being weighed.

   **Apply the edit when the working tree is clean**, and show the `git diff`; when it
   is dirty, propose the diff and change nothing. Only this file, never `git
add`/`commit`/`push`.

   **Then sweep this whole file before finishing — every run.** Read it end to end and
   fix contradiction, duplication (keep guidance where it is acted on, cross-reference
   elsewhere), staleness (every literal here is a claim about the network — verify the
   ones this run touched), hardcoded addresses that should be discovery queries,
   expired dated notes, and bloat. Say **"swept, nothing to tidy"** when it found
   nothing — silence is indistinguishable from not looking.

   **Repetition is itself a finding.** This file is the check's only memory. A warning
   accepted for the same reason more than twice → promote it to the accept-list or to
   a standing condition. A 🔧 that keeps reappearing unfixed → say how many runs it has
   survived and treat that as escalation, not a fresh finding. A standing condition
   whose numbers drifted past its baseline → re-open it. Something that fires every run
   and is always fine → the threshold is wrong, not the network.

If everything is green, say so plainly — don't invent work.
