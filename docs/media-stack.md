# Media Stack (ARR + Usenet)

Automated media acquisition and streaming stack running on k3s, managed by ArgoCD. All services live in the `media` namespace.

## Architecture

```
Request flow:
  Pulsarr/Prismarr/Searcharr (requests) → Sonarr/Radarr (automation) → Prowlarr (indexer search) → SABnzbd/qBittorrent (download) → Plex (playback)

Push flow:
  Autobrr (filtered release announcements) → Sonarr/Radarr (grab)

Config flow:
  Profilarr (curated quality profiles + custom formats) → Sonarr/Radarr (sync)

Download flow:
  SABnzbd      → Gluetun VPN → Usenet provider  → NFS media library
  qBt (SE, BR, MAM) → Gluetun VPN → Torrent trackers → NFS media library

DNS/indexer flow:
  Prowlarr → DrunkenSlug / NZBFinder (NZB search)
  SABnzbd  → xsnews.nl (primary) / news.eweka.nl (secondary)
```

## Services

| Service   | URL                                 | Port  | Purpose                                    |
| --------- | ----------------------------------- | ----- | ------------------------------------------ |
| SABnzbd   | `https://sabnzbd.hl.mathielo.com`   | 8080  | Usenet downloader                          |
| qBt SE    | `https://qbt-se.hl.mathielo.com`    | 8080  | Torrent downloader                         |
| qBt BR    | `https://qbt-br.hl.mathielo.com`    | 8080  | Torrent downloader                         |
| qBt MAM   | `https://qbt-mam.hl.mathielo.com`   | 8080  | Torrent downloader (MyAnonaMouse-only)     |
| qui       | `https://qui.hl.mathielo.com`       | 7476  | Multi-qBt instance manager UI + cross-seed |
| Prowlarr  | `https://prowlarr.hl.mathielo.com`  | 9696  | Indexer manager/proxy                      |
| Radarr    | `https://radarr.hl.mathielo.com`    | 7878  | Movie automation                           |
| Sonarr    | `https://sonarr.hl.mathielo.com`    | 8989  | Shows automation                           |
| Bazarr    | `https://bazarr.hl.mathielo.com`    | 6767  | Subtitle automation                        |
| Plex      | `https://plex.hl.mathielo.com`      | 32400 | Media server / playback                    |
| Autobrr   | `https://autobrr.hl.mathielo.com`   | 7474  | Filtered release automation                |
| Pulsarr   | `https://pulsarr.hl.mathielo.com`   | 3003  | Automated media requests (Sonarr/Radarr)   |
| Prismarr  | `https://prismarr.hl.mathielo.com`  | 7070  | Media request portal                       |
| Profilarr | `https://profilarr.hl.mathielo.com` | 6868  | Quality profiles / custom formats          |

> Searcharr (Telegram request bot) also runs in `media` but has no web UI.

> Profilarr runs a bundled stateless `profilarr-parser` sidecar (in-pod, port 5000) that powers release-pattern testing; it has no web UI of its own.

> :exclamation: All URLs require Tailscale (or LAN) + Pi-hole DNS (`*.hl.mathielo.com → 10.10.50.3`).

## External Services

### Usenet Providers (configured in SABnzbd)

| Provider | Server          | Port | SSL | Role      |
| -------- | --------------- | ---- | --- | --------- |
| XS News  | `xsnews.nl`     | 563  | Yes | Primary   |
| Eweka    | `news.eweka.nl` | 563  | Yes | Secondary |

### Indexers (configured in Prowlarr)

| Indexer     | URL                       | Type   |
| ----------- | ------------------------- | ------ |
| DrunkenSlug | `https://drunkenslug.com` | Usenet |
| NZBFinder   | `https://nzbfinder.ws`    | Usenet |

### Subtitles (configured in Bazarr)

| Provider          | URL                             |
| ----------------- | ------------------------------- |
| OpenSubtitles.com | `https://www.opensubtitles.com` |

> :bulb: OpenSubtitles.com requires a free account. The API key is generated from your account profile page.

## Storage Layout

All services share the `media-data` PVC (NFS-backed from UNAS-4, mounted at `/media` in every pod). Download clients write to `dl/`; ARR apps hardlink completed files into `lib/`. Both trees are on the same NFS volume, which is what enables instant, zero-copy hardlinks on import.

```
/media/                          ← NFS mount from UNAS-4 (52 TB)
├── dl/                          ← download clients write here
│   ├── movies/                  ← qBittorrent "movies" category → Radarr imports from here
│   ├── shows/                   ← qBittorrent "shows" category → Sonarr imports from here
│   └── usenet/                  ← SABnzbd download root
└── lib/                         ← ARR apps hardlink here; media servers read here
    ├── movies/                  ← Radarr root folder, Plex movies library
    └── shows/                   ← Sonarr root folder, Plex shows library
```

### qBittorrent Categories → ARR Correlation

qBittorrent categories define the per-category save path (`dl/<category>`). ARR download clients must be configured with the **matching category name** so Sonarr/Radarr can track and import only their own downloads.

| qBittorrent category | Save path          | ARR service | Download client category in ARR |
| -------------------- | ------------------ | ----------- | ------------------------------- |
| `movies`             | `/media/dl/movies` | Radarr      | `movies`                        |
| `shows`              | `/media/dl/shows`  | Sonarr      | `shows`                         |

Categories and per-instance preferences are managed declaratively via scripts in [scripts/qbt/](../scripts/qbt/): `apply-categories.sh <instance>` pushes [`categories.yaml`](../scripts/qbt/categories.yaml) (category → save path) and `apply-prefs.sh <instance>` pushes [`prefs.yaml`](../scripts/qbt/prefs.yaml), both through the WebUI API.

> :bulb: qBittorrent persists categories to `/config/config/categories.json` on the Longhorn config PVC, so they survive pod restarts; the scripts are the source of truth and re-apply them to a fresh instance.

## VPN Kill-Switch (Gluetun)

SABnzbd and qBittorrent both run behind a Gluetun VPN sidecar for privacy:

- **VPN provider:** ProtonVPN (WireGuard)
- **Server locations:** Sweden (`qbt-se`, SABnzbd), Brazil (`qbt-br`), and a fixed single-ASN set of Sweden servers (`qbt-mam`) — one WireGuard profile per exit
- **Kill-switch:** If the VPN tunnel drops, all download traffic is blocked (Gluetun firewall)
- **Bypass subnets:** `10.42.0.0/16` and `10.43.0.0/16` (k3s pod/service CIDRs) so in-cluster communication still works

Credentials (`WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`) are encrypted per instance in `values-<instance>.sops.yaml`.

### MyAnonaMouse dynamic seedbox (qbt-mam)

MAM gates download/announce permission on the requesting IP via an ASN-locked session. To keep that lock matched, `qbt-mam` is a dedicated instance pinned to a fixed set of Stockholm ProtonVPN servers. A `mam` sidecar calls [`dynamicSeedbox`](https://www.myanonamouse.net/api/endpoint.php/3/json/dynamicSeedbox.php) hourly to keep the seedbox IP current.

- **Seedbox session:** MAM **Preferences → Security** → "Allow session to set dynamic seedbox IP", then ASN-lock it (after the first successful call registers the right ASN). Separate from the browser session. Its `mam_id` is stored as `MAM_ID` in `values-mam.sops.yaml` and seeds a cookie jar at `/config/mam/cookies.txt`.

## Setting Up Services

After ArgoCD deploys the pods, each service needs manual UI configuration. Follow this order — each step depends on the previous ones.

> :bulb: For app-to-app connections, always use in-cluster URLs (`<app>.media.svc.cluster.local`) — faster and doesn't leave the cluster.

### Step 1: SABnzbd

Complete the setup wizard, then configure:

**Config → Servers** — add both providers:

| Setting     | XS News (primary) | Eweka (secondary) |
| ----------- | ----------------- | ----------------- |
| Host        | `xsnews.nl`       | `news.eweka.nl`   |
| Port        | `563`             | `563`             |
| SSL         | Yes               | Yes               |
| Connections | `50`              | `25`              |
| Priority    | `0`               | `1`               |

**Config → Folders:**

| Setting                   | Path          |
| ------------------------- | ------------- |
| Temporary Download Folder | `/incomplete` |
| Completed Download Folder | `/media/dl`   |

**Config → Categories:**

| Category | Folder             |
| -------- | ------------------ |
| `movies` | `/media/dl/movies` |
| `shows`  | `/media/dl/shows`  |

Note the **API key** from Config → General → Security.

### Step 2: qui + qBittorrent instances

Instances config and categories are managed via scripts in [scripts/qbt/](../scripts/qbt/).

Note the **WebUI credentials** — password is managed in `values.sops.yaml`.

### Step 3: Prowlarr

Set up authentication, then add indexers via **Settings → Indexers**:

| Indexer     | Type    | URL                       | Auth    |
| ----------- | ------- | ------------------------- | ------- |
| DrunkenSlug | Newznab | `https://drunkenslug.com` | API key |
| NZBFinder   | Newznab | `https://nzbfinder.ws`    | API key |

After Steps 4–5 are done, come back to **Settings → Apps** and add:

| App    | URL                                          | Sync      |
| ------ | -------------------------------------------- | --------- |
| Sonarr | `http://sonarr.media.svc.cluster.local:8989` | Full Sync |
| Radarr | `http://radarr.media.svc.cluster.local:7878` | Full Sync |

Set Prowlarr Server to `http://prowlarr.media.svc.cluster.local:9696`. Each app connection requires the respective API key.

### Step 4: Radarr

Set up authentication, then:

1. **Settings → Media Management** — root folder: `/media/lib/movies`, enable Rename Movies
2. **Settings → Download Clients** — add both clients:
   - SABnzbd: host `sabnzbd.media.svc.cluster.local`, port `8080`, category `movies`
   - qBittorrent: host `qbt-{br,se}.media.svc.cluster.local`, port `8080`, category `movies`
3. **Settings → Profiles** — configure quality profiles

Note the **API key** from Settings → General.

### Step 5: Sonarr

Set up authentication, then:

1. **Settings → Media Management** — root folder: `/media/lib/shows`, enable Rename Episodes
2. **Settings → Download Clients** — add both clients:
   - SABnzbd: host `sabnzbd.media.svc.cluster.local`, port `8080`, category `shows`
   - qBittorrent: host `qbt-{br,se}.media.svc.cluster.local`, port `8080`, category `shows`
3. **Settings → Profiles** — configure quality profiles

Note the **API key** from Settings → General.

> :bulb: Now go back to Prowlarr (Step 3) and add Sonarr/Radarr as apps so indexers sync automatically.

### Step 6: Bazarr

Set up authentication, then connect to Sonarr and Radarr:

| Setting | Sonarr                           | Radarr                           |
| ------- | -------------------------------- | -------------------------------- |
| Host    | `sonarr.media.svc.cluster.local` | `radarr.media.svc.cluster.local` |
| Port    | `8989`                           | `7878`                           |
| API Key | Sonarr API key                   | Radarr API key                   |

Then configure **Settings → Languages** and add **OpenSubtitles.com** under **Settings → Providers** (requires account credentials + API key).

> :bulb: Bazarr writes sidecar `.srt` files next to the media on the shared NFS mount, so Plex picks them up automatically — no per-media-server Bazarr configuration needed.

### Step 7: Plex

> :bulb: Plex is pinned to `k3s-server` (M75q-1) via hostname nodeSelector for access to the Radeon Vega 10 GPU.

Complete the setup wizard at `https://plex.hl.mathielo.com`, then:

1. **Claim server** — should auto-claim via `PLEX_CLAIM` env var on first boot. If the token expired, generate a new one at `https://plex.tv/claim`, re-encrypt `values.sops.yaml`, and redeploy.

2. **Add libraries:**

| Library | Content Type | Folder              |
| ------- | ------------ | ------------------- |
| Movies  | Movies       | `/media/lib/movies` |
| Shows   | TV Shows     | `/media/lib/shows`  |

3. **Enable hardware transcoding** (requires Plex Pass):
   - Settings → Transcoder → check "Use hardware acceleration when available"
   - The AMD Radeon Vega 10 GPU is passed through via `amd.com/gpu` resource request

4. **Get API token** for Homepage widget:
   - In Plex web UI, open any media item, click "Get Info", check the URL for `X-Plex-Token=`
   - Update `HOMEPAGE_VAR_PLEX_TOKEN` in `k3s/apps/dashboard/homepage/values.sops.yaml`

### Step 8: Pulsarr

Pulsarr automates adding content to Sonarr/Radarr based on Plex watchlists and friends' activity.

Complete the setup wizard, then connect media services under **Settings → Media Server**:

| Setting   | Value                                       |
| --------- | ------------------------------------------- |
| Host      | `http://plex.media.svc.cluster.local:32400` |
| API Token | Plex API token (from Step 7)                |

Then under **Settings → Sonarr** and **Settings → Radarr**, add each service:

| Setting | Sonarr                                       | Radarr                                       |
| ------- | -------------------------------------------- | -------------------------------------------- |
| Host    | `http://sonarr.media.svc.cluster.local:8989` | `http://radarr.media.svc.cluster.local:7878` |
| API Key | Sonarr API key                               | Radarr API key                               |

### Step 9: Prismarr

Complete the setup wizard, then connect media services:

| Service | URL                                          | Auth                                      |
| ------- | -------------------------------------------- | ----------------------------------------- |
| Plex    | `http://plex.media.svc.cluster.local:32400`  | API key                                   |
| Radarr  | `http://radarr.media.svc.cluster.local:7878` | API key + root folder `/media/lib/movies` |
| Sonarr  | `http://sonarr.media.svc.cluster.local:8989` | API key + root folder `/media/lib/shows`  |

### Step 10: Profilarr

Profilarr replaces hand-tuned quality profiles with curated, importable ones and keeps them synced into Sonarr/Radarr.

Browse `https://profilarr.hl.mathielo.com` and create the admin account (built-in auth is on). Then:

1. **Settings → Arr** — add Sonarr and Radarr:

   | Setting | Sonarr                                       | Radarr                                       |
   | ------- | -------------------------------------------- | -------------------------------------------- |
   | URL     | `http://sonarr.media.svc.cluster.local:8989` | `http://radarr.media.svc.cluster.local:7878` |
   | API Key | Sonarr API key                               | Radarr API key                               |

2. **Database** — import a profile database (e.g. the Dictionarry database), then select or build the quality profiles / custom formats you want.
3. **Sync** — push the selected profiles to Sonarr/Radarr. The in-pod `profilarr-parser` sidecar powers the release-regex testing used when building/validating formats.

> :bulb: Profilarr stores its config and the \*arr API keys in its own `/config` (Longhorn `profilarr-config-lh` PVC) — no `values.sops.yaml` is required.
