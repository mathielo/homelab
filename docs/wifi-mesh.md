# WiFi & Mesh Backhaul

The apartment has no in-wall ethernet and no cross-room cable runs are possible, so
three UniFi Dream Bridge switches (UDBs) reach the network over **wireless mesh
backhaul**. Every byte between the k3s cluster / NAS and the rest of the world
crosses one of those mesh links — which makes this layer the first suspect for any
"X is slow" report.

This document covers the RF layout, how to measure a mesh link correctly, and the
traps that make a healthy link look broken.

## Topology

Wired spine: **USW Flex 2.5G 8 PoE**, uplinked to the R18 UGC Max on port 4 at
2.5 GbE. Both APs are wired to it at 2.5 GbE.

All UniFi devices are on VLAN 1 with DHCP addresses, so **the MAC suffix is the
stable identifier — IPs change**. Resolve a suffix to its current address from the
gateway:

```sh
ssh UGCMax 'ip neigh show | grep -i "<mac-suffix>"'
```

| Device    | MAC suffix  | Radios                                   |
| --------- | ----------- | ---------------------------------------- |
| U7 Pro XG | `…3e:6b:ac` | 2.4 ch11@20 · 5 ch36@80 · **6 ch37@320** |
| U7 Mesh   | `…ea:d9:a4` | 2.4 **auto** · 5 **ch104@40 (DFS)**      |

Mesh children:

| UDB         | MAC suffix  | Parent    | Link(s)                  |
| ----------- | ----------- | --------- | ------------------------ |
| Homelab     | `…1a:b5:f2` | U7 Pro XG | MLO: 5 ch36 **+** 6 ch37 |
| Living Room | `…1a:b7:2e` | U7 Pro XG | 6 ch37                   |
| G6 Balcony  | `…b4:7e:b9` | U7 Mesh   | 5 ch104                  |

A UDB's per-link MACs are its base MAC with the last octet incremented — e.g.
`…b5:f4` is the 5 GHz link and `…b5:f5` the 6 GHz link of the same MLD. That is how
you tell which row in `wlanconfig` output belongs to which device.

> :warning: MACs are deliberately truncated here. **AP MACs are the basis of the
> BSSIDs broadcast in beacons**, which wardriving/geolocation databases index against
> physical coordinates — publishing them in a public repo tied to a real identity is a
> home-address disclosure vector. Suffixes are enough to match runtime output. Keep
> full MACs (and UI screenshots that show BSSIDs) out of this repo.

`UDB Homelab` carries the k3s nodes, the UNAS-4 and the workstation, so its link is
the one that matters for cluster throughput. See
[`hardware.md`](hardware.md) for what hangs off each port.

### Why this layout

- **The U7 Pro XG is the network's only 6 GHz radio.** The U7 Mesh is dual-band
  (2.4 + 5 only) despite the "U7" name — verify the model, don't assume.
- **Region SE**: 5 GHz non-DFS is only ch 36–48 (one 80 MHz block); there is no
  UNII-3 (ch149+). 6 GHz is wide open (ch 1–93, PSC 5/21/37/53/69/85).
- **ch36 @ 80 MHz spans channels 36–48.** Anything else on 44 or 48 is fully
  overlapped by it. This is the single easiest way to wreck the backhaul — see
  [Co-channel collision](#co-channel-collision-between-our-own-aps) below.
- The Balcony is dual-band and can only reach an AP on 5 GHz, so it lives on the
  U7 Mesh to keep it off the XG's ch36.

## Measuring a mesh link

**Do not judge MLO mesh health from the controller's per-station data.** Use the
parent AP's per-VAP interface counters. On the U7 Pro XG, `vwireap10` is the 5 GHz
mesh VAP and `vwireap11` is the 6 GHz one; the AP's `tx` is downstream (AP → UDB).

APs are not reachable from the workstation VLAN — jump via the gateway. Host aliases
and the UniFi device SSH user are in [`.config/ssh.config`](../.config/ssh.config);
`$UNIFI_SSH_USER` is that user and `$XG` the AP's current IP (resolve it from the MAC
suffix as shown above).

```sh
ssh -J UGCMax "$UNIFI_SSH_USER@$XG" \
  'a=$(grep -E "vwireap10:|vwireap11:" /proc/net/dev); sleep 30; \
   grep -E "vwireap10:|vwireap11:" /proc/net/dev; echo "$a"'
```

Diff field 2 (rx bytes) and field 10 (tx bytes) across the two reads and divide by
the interval. Cross-check against the child's own NIC:

```sh
ssh k3s-node-02 'grep eno1: /proc/net/dev'
```

**If the two agree within a few percent, the mesh is not your bottleneck** — it is
delivering exactly what is being asked of it. A real mesh ceiling shows up as the
mesh figure pinned flat while demand runs above it.

Link state and PHY rates:

```sh
ssh -J UGCMax "$UNIFI_SSH_USER@$XG" 'wlanconfig mld0 list sta'
```

## Three traps

All three of these made a working 6 GHz link look completely dead during the
2026-08-05 investigation. Each cost real time.

1. **The controller's `uplink` object shows only ONE link of an MLO pair.** It will
   report a device as "meshing on 5 GHz" while a second 6 GHz link is up and
   carrying most of the traffic.

2. **All MLO traffic is accounted to the _primary_ link's station entry.** The
   controller's `downlink_table` per-station `tx_bytes`/`rx_bytes` read ≈0 on the
   secondary link even while it moves hundreds of Mbit/s. Anything built on that same
   API inherits the distortion: a per-band series tracks which link is _primary_, not
   which is loaded.

3. **The secondary link legitimately reports `STATE 3` with blank `HTCAPS` and
   `IEs: 00`** (the primary shows `1000000b`). This is not a fault — association and
   IE state live on the primary link entry. Links were observed sitting at `STATE 3`
   while measurably forwarding 452 Mbit/s.

## MLO children need a 6 GHz-capable parent

A WiFi 7 MLO UDB **cannot** be pinned to a parent that lacks a 6 GHz radio, even
though the UI offers it. Pinning `UDB Living Room` to the U7 Mesh failed
reproducibly: it associated cleanly (`WPA: authorized`), then ~8 s later the AP
logged `Receive UBNT_ROAM from <XG 6 GHz mesh BSSID>` and issued `immed disassoc`.

The MLD was announcing `target band(1) ch104` **and** `target band(2) ch37` — trying
to span two different APs, which is not valid MLO — and bounced until the device went
`error/heartbeat_missed` and took its wired clients offline with it.

**Pin MLO UDBs to the U7 Pro XG, or leave them on Auto.** DFS was not the cause here;
the link associated on ch104 without trouble.

## Co-channel collision between our own APs

The 2026-08-05 backhaul ceiling (~300 Mbit/s against a ~690 Mbit/s WAN) was caused
entirely by our own two APs, not by neighbours:

- XG 5 GHz on **ch36 @ 80 MHz** spans 36–48, fully containing the U7 Mesh's then
  **ch44 @ 40 MHz**.
- U7 Mesh read **84% channel utilisation / 77.9% interference with 1% self-tx** — it
  was blocked, and blocking the XG in return.
- XG 5 GHz sat at 85–92% CU with 15–21% retries and its PHY rate sagging 721 → 648 Mbps.

Moving the U7 Mesh's 5 GHz to **ch104** dropped its CU to 1% and took mesh throughput
from ~300 to ~709 Mbit/s. Restarting the APs and UDBs did **not** fix it — only the
channel change did.

> :bulb: A full airtime scan on 2026-08-05 returned **"No WiFi broadcasts found"** on
> 5 GHz with an almost entirely green channel grid. Neighbour congestion is no longer
> the problem here; suspect our own overlap first.

### Reading the utilisation numbers

`cu_total` alone is misleading. Subtract `cu_self_tx + cu_self_rx` to get what is
actually _someone else's_ airtime. High utilisation from our own useful traffic is
fine; high utilisation from an external source is not.

## Known-good baseline

Verified 2026-08-05 under combined load (cluster downloads plus a 4K Plex stream, ~19
minutes of one-minute samples):

| Metric                       | Value                                  |
| ---------------------------- | -------------------------------------- |
| Mesh downstream peak         | 663 Mbit/s (WAN speedtest 688/726)     |
| Mesh downstream range        | 260–663 Mbit/s, tracking demand        |
| Mesh vs child NIC divergence | mean 1.0%, max 3.2% (no queueing/loss) |
| Stalls                       | 0                                      |
| XG 5 GHz ch36                | 61% CU, **6% external**, 10.5% retries |
| XG 6 GHz ch37                | 56% CU, **7% external**, 15.0% retries |

At these numbers the path is WAN-limited, not mesh-limited. Throughput varying with
demand is expected and is not a fault.

## Gotchas

- **DFS on a mesh parent costs availability.** ch104 needs a 60 s Channel
  Availability Check before the AP may beacon, so after a simultaneous restart the
  parent is invisible while children are already scanning. A radar detection forces it
  off-channel within 10 s for 30 minutes, taking its children with it.
- **Avoid the weather-radar sub-band on 5 GHz.** ch116 at 80 MHz spans 5570–5650,
  overlapping the 5600–5650 weather-radar allocation; a detection there wedges the
  radio rather than merely moving it. Prefer non-DFS ch36. The validated assignment is
  2.4 GHz ch11 / 5 GHz ch36 / 6 GHz ch37 at 320 MHz.
- **Do not widen the XG's 5 GHz to 160 MHz.** A 160 MHz block anchored at ch36 spans
  36–64, dragging in DFS channels 52–64 and the availability cost above.
- **A slow client is airtime-expensive out of proportion to its bytes.** The Balcony
  at −80 dBm on 11ac rates consumed far more ch36 airtime than its ~4 Mbit/s of
  traffic suggested. Moving it to ch104 both freed XG airtime and improved its own
  link (−78 → −70 dBm).
- **AP log buffers are small** and do not survive long — capture them while the fault
  is live. Nothing retains AP-side history, so a fault that is not captured live is
  gone.
