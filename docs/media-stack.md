# Media Stack (ARR + Usenet)

Automated media acquisition and streaming stack running on k3s, managed by ArgoCD. All services live in the `media` namespace.

## Architecture

```
Request flow:
  Pulsarr/Searcharr (requests) → Sonarr/Radarr (automation) → Prowlarr (indexer search) → SABnzbd/qBittorrent (download) → Plex (playback)

Cleanup flow:
  Maintainerr (rules) → Radarr/Sonarr (remove entry) → deletes files from NFS media library

Download flow:
  SABnzbd     → Gluetun VPN → Usenet provider  → NFS media library
  qBittorrent → Gluetun VPN → Torrent trackers → NFS media library

DNS/indexer flow:
  Prowlarr → DrunkenSlug / NZBFinder (NZB search)
  SABnzbd  → xsnews.nl (primary) / news.eweka.nl (secondary)
```

## Services

| Service     | URL                                   | Port  | Purpose                                  |
| ----------- | ------------------------------------- | ----- | ---------------------------------------- |
| SABnzbd     | `https://sabnzbd.hl.mathielo.com`     | 8080  | Usenet downloader                        |
| qBittorrent | `https://qbt.hl.mathielo.com`         | 8080  | Torrent downloader                       |
| Prowlarr    | `https://prowlarr.hl.mathielo.com`    | 9696  | Indexer manager/proxy                    |
| Radarr      | `https://radarr.hl.mathielo.com`      | 7878  | Movie automation                         |
| Sonarr      | `https://sonarr.hl.mathielo.com`      | 8989  | Shows automation                         |
| Bazarr      | `https://bazarr.hl.mathielo.com`      | 6767  | Subtitle automation                      |
| Plex        | `https://plex.hl.mathielo.com`        | 32400 | Media server / playback                  |
| Pulsarr     | `https://pulsarr.hl.mathielo.com`     | 3003  | Automated media requests (Sonarr/Radarr) |
| Prismarr    | `https://prismarr.hl.mathielo.com`    | 7070  | Media request portal                     |
| Maintainerr | `https://maintainerr.hl.mathielo.com` | 6246  | Media library cleanup                    |

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
│   ├── books/                   ← qBittorrent "books" category
│   ├── comics/                  ← qBittorrent "comics" category
│   ├── courses/                 ← qBittorrent "courses" category
│   ├── freeleech/               ← qBittorrent "freeleech" category
│   ├── games/                   ← qBittorrent "games" category
│   ├── magazines/               ← qBittorrent "magazines" category
│   ├── movies/                  ← qBittorrent "movies" category → Radarr imports from here
│   ├── shows/                   ← qBittorrent "shows" category → Sonarr imports from here
│   └── _torrents/               ← qBittorrent exports .torrent files here (TorrentExportDirectory)
└── lib/                         ← ARR apps hardlink here; media servers read here
    ├── books/
    ├── movies/                  ← Radarr root folder, Plex movies library
    ├── music/
    └── shows/                   ← Sonarr root folder, Plex shows library
```

In-progress downloads land on **local SSDs** (not NFS) for speed, then move to `dl/` when complete:

| Client      | In-progress path | Storage                                                       |
| ----------- | ---------------- | ------------------------------------------------------------- |
| qBittorrent | `/incomplete`    | hostPath `/mnt/ssd/local/qbt-incomplete` on `k3s-node-01`     |
| SABnzbd     | `/incomplete`    | hostPath `/mnt/ssd/local/sabnzbd-incomplete` on `k3s-node-01` |

### qBittorrent Categories → ARR Correlation

qBittorrent categories define the per-category save path (`dl/<category>`). ARR download clients must be configured with the **matching category name** so Sonarr/Radarr can track and import only their own downloads.

| qBittorrent category | Save path          | ARR service | Download client category in ARR |
| -------------------- | ------------------ | ----------- | ------------------------------- |
| `movies`             | `/media/dl/movies` | Radarr      | `movies`                        |
| `shows`              | `/media/dl/shows`  | Sonarr      | `shows`                         |

Categories are defined in qBittorrent's **Settings → Downloads → Default Save Path** (for the default) and **Tools → Options → Downloads → Default Torrent Management Mode** (for AutoTMM). Per-category save paths are set in the **Tags & Categories** section of the web UI.

> :bulb: Categories are stored in `/config/config/categories.json` on the Longhorn config PVC. They survive pod restarts and are **not** managed by the declarative ConfigMap (which only covers `qBittorrent.conf`).

## VPN Kill-Switch (Gluetun)

SABnzbd and qBittorrent both run behind a Gluetun VPN sidecar for privacy:

- **VPN provider:** ProtonVPN (WireGuard)
- **Server location:** Sweden
- **Kill-switch:** If the VPN tunnel drops, all download traffic is blocked (Gluetun firewall)
- **Bypass subnets:** `10.42.0.0/16` and `10.43.0.0/16` (k3s pod/service CIDRs) so in-cluster communication still works

Credentials (`WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`) are encrypted in each service's `values.sops.yaml`.

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

### Step 2: qBittorrent

qBittorrent's `qBittorrent.conf` is managed declaratively (see `files/qBittorrent.conf` in the chart). The categories below must be configured in the web UI; they are stored on the config PVC and survive pod restarts.

**Tools → Options → Downloads → Saving Management**

| Setting                | Path                   |
| ---------------------- | ---------------------- |
| Keep incomplete in     | `/incomplete`          |
| Default save path      | `/media/dl`            |
| Copy .torrent files to | `/media/_dl/_torrents` |

**Tags & Categories** — create each category with its save path:

| Category    | Save path             |
| ----------- | --------------------- |
| `books`     | `/media/dl/books`     |
| `comics`    | `/media/dl/comics`    |
| `courses`   | `/media/dl/courses`   |
| `freeleech` | `/media/dl/freeleech` |
| `games`     | `/media/dl/games`     |
| `magazines` | `/media/dl/magazines` |
| `movies`    | `/media/dl/movies`    |
| `shows`     | `/media/dl/shows`     |

**Tools → Options → Web UI:**

- Enable "Bypass authentication for clients on localhost" — required so Gluetun's port-forwarding hook can call the API without credentials.
- The WebUI subnet whitelist (`10.42.0.0/16`) and password are set declaratively in the ConfigMap.

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
   - qBittorrent: host `qbittorrent.media.svc.cluster.local`, port `8080`, category `movies`
3. **Settings → Profiles** — configure quality profiles

Note the **API key** from Settings → General.

### Step 5: Sonarr

Set up authentication, then:

1. **Settings → Media Management** — root folder: `/media/lib/shows`, enable Rename Episodes
2. **Settings → Download Clients** — add both clients:
   - SABnzbd: host `sabnzbd.media.svc.cluster.local`, port `8080`, category `shows`
   - qBittorrent: host `qbittorrent.media.svc.cluster.local`, port `8080`, category `shows`
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

| Service | URL                                          | Auth                                          |
| ------- | -------------------------------------------- | --------------------------------------------- |
| Plex    | `http://plex.media.svc.cluster.local:32400`  | API key                                       |
| Radarr  | `http://radarr.media.svc.cluster.local:7878` | API key + root folder `/media/library/movies` |
| Sonarr  | `http://sonarr.media.svc.cluster.local:8989` | API key + root folder `/media/library/shows`  |
