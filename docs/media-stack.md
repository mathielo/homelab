# Media Stack (ARR + Usenet)

Automated media acquisition and streaming stack running on k3s, managed by ArgoCD. All services live in the `media` namespace.

## Architecture

```
Request flow:
  Seerr (requests) → Sonarr/Radarr (automation) → Prowlarr (indexer search) → SABnzbd (download) → Jellyfin/Plex (playback)

Download flow:
  SABnzbd → Gluetun VPN → Usenet provider → NFS media library

DNS/indexer flow:
  Prowlarr → DrunkenSlug / NZBFinder (NZB search)
  SABnzbd  → xsnews.nl (primary) / news.eweka.nl (secondary)
```

## Services

| Service  | URL                                | Port | Purpose                 |
| -------- | ---------------------------------- | ---- | ----------------------- |
| SABnzbd  | `https://sabnzbd.hl.mathielo.com`  | 8080 | Usenet downloader       |
| Prowlarr | `https://prowlarr.hl.mathielo.com` | 9696 | Indexer manager/proxy   |
| Radarr   | `https://radarr.hl.mathielo.com`   | 7878 | Movie automation        |
| Sonarr   | `https://sonarr.hl.mathielo.com`   | 8989 | Shows automation        |
| Bazarr   | `https://bazarr.hl.mathielo.com`   | 6767 | Subtitle automation     |
| Jellyfin | `https://jellyfin.hl.mathielo.com` | 8096 | Media server / playback |
| Plex     | `https://plex.hl.mathielo.com`     | 32400 | Media server / playback |
| Seerr    | `https://seerr.hl.mathielo.com`    | 5055 | Media request portal    |

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

All services share the `media-data` PVC (NFS-backed from UNAS-4):

```
/media/                          ← mount point in all pods
├── downloads/usenet/
│   ├── incomplete/              ← SABnzbd active downloads (also on local SSD)
│   └── complete/
│       ├── movies/              ← SABnzbd category output → Radarr imports from here
│       ├── shows/               ← SABnzbd category output → Sonarr imports from here
│       └── music/
└── library/
    ├── movies/                  ← Radarr root folder, Jellyfin movies library
    ├── shows/                   ← Sonarr root folder, Jellyfin shows library
    └── music/
```

> :bulb: All services mount `/media` from the same NFS PVC. This enables hardlinks — when Sonarr/Radarr "import" a completed download, they hardlink instead of copying, which is instant and uses no extra disk space.

## VPN Kill-Switch (SABnzbd + Gluetun)

SABnzbd runs behind a Gluetun VPN sidecar for privacy:

- **VPN provider:** ProtonVPN (WireGuard)
- **Server location:** Sweden
- **Kill-switch:** If the VPN tunnel drops, all SABnzbd traffic is blocked (Gluetun firewall)
- **Bypass subnets:** `10.42.0.0/16` and `10.43.0.0/16` (k3s pod/service CIDRs) so in-cluster communication still works

Credentials (`WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`) are encrypted in `k3s/apps/media/sabnzbd/values.sops.yaml`.

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

| Setting                   | Path                               |
| ------------------------- | ---------------------------------- |
| Temporary Download Folder | `/local-ssd/downloads`             |
| Completed Download Folder | `/media/downloads/usenet/complete` |

**Config → Categories:**

| Category | Folder                                    |
| -------- | ----------------------------------------- |
| `movies` | `/media/downloads/usenet/complete/movies` |
| `shows`  | `/media/downloads/usenet/complete/shows`  |

Note the **API key** from Config → General → Security.

### Step 2: Prowlarr

Set up authentication, then add indexers via **Settings → Indexers**:

| Indexer     | Type    | URL                       | Auth    |
| ----------- | ------- | ------------------------- | ------- |
| DrunkenSlug | Newznab | `https://drunkenslug.com` | API key |
| NZBFinder   | Newznab | `https://nzbfinder.ws`    | API key |

After Steps 3–4 are done, come back to **Settings → Apps** and add:

| App    | URL                                          | Sync      |
| ------ | -------------------------------------------- | --------- |
| Sonarr | `http://sonarr.media.svc.cluster.local:8989` | Full Sync |
| Radarr | `http://radarr.media.svc.cluster.local:7878` | Full Sync |

Set Prowlarr Server to `http://prowlarr.media.svc.cluster.local:9696`. Each app connection requires the respective API key.

### Step 3: Radarr

Set up authentication, then:

1. **Settings → Media Management** — root folder: `/media/library/movies`, enable Rename Movies
2. **Settings → Download Clients** — add SABnzbd: host `sabnzbd.media.svc.cluster.local`, port `8080`, category `movies`
3. **Settings → Profiles** — configure quality profiles

Note the **API key** from Settings → General.

### Step 4: Sonarr

Set up authentication, then:

1. **Settings → Media Management** — root folder: `/media/library/shows`, enable Rename Episodes
2. **Settings → Download Clients** — add SABnzbd: host `sabnzbd.media.svc.cluster.local`, port `8080`, category `shows`
3. **Settings → Profiles** — configure quality profiles

Note the **API key** from Settings → General.

> :bulb: Now go back to Prowlarr (Step 2) and add Sonarr/Radarr as apps so indexers sync automatically.

### Step 5: Bazarr

Set up authentication, then connect to Sonarr and Radarr:

| Setting | Sonarr                           | Radarr                           |
| ------- | -------------------------------- | -------------------------------- |
| Host    | `sonarr.media.svc.cluster.local` | `radarr.media.svc.cluster.local` |
| Port    | `8989`                           | `7878`                           |
| API Key | Sonarr API key                   | Radarr API key                   |

Then configure **Settings → Languages** and add **OpenSubtitles.com** under **Settings → Providers** (requires account credentials + API key).

### Step 6: Jellyfin

Complete the setup wizard, then add media libraries:

| Library | Content Type | Folder                  |
| ------- | ------------ | ----------------------- |
| Movies  | Movies       | `/media/library/movies` |
| Shows   | Shows        | `/media/library/shows`  |

Optional: enable VA-API hardware transcoding (AMD Radeon Vega 8 available via `amdgpu-device-plugin`, uncomment GPU resource requests in `k3s/apps/media/jellyfin/values.yaml`).

Note the **API key** from Dashboard → API Keys.

### Step 7: Plex

> :bulb: Plex is pinned to `k3s-server` (M75q-1) via hostname nodeSelector for access to the Radeon Vega 10 GPU.

Complete the setup wizard at `https://plex.hl.mathielo.com`, then:

1. **Claim server** — should auto-claim via `PLEX_CLAIM` env var on first boot. If the token expired, generate a new one at `https://plex.tv/claim`, re-encrypt `values.sops.yaml`, and redeploy.

2. **Add libraries:**

| Library | Content Type | Folder                  |
| ------- | ------------ | ----------------------- |
| Movies  | Movies       | `/media/library/movies` |
| Shows   | TV Shows     | `/media/library/shows`  |

3. **Enable hardware transcoding** (requires Plex Pass):
   - Settings → Transcoder → check "Use hardware acceleration when available"
   - The AMD Radeon Vega 10 GPU is passed through via `amd.com/gpu` resource request

4. **Get API token** for Homepage widget:
   - In Plex web UI, open any media item, click "Get Info", check the URL for `X-Plex-Token=`
   - Update `HOMEPAGE_VAR_PLEX_TOKEN` in `k3s/apps/dashboard/homepage/values.sops.yaml`

### Step 8: Seerr

Sign in, then connect all services:

| Service  | URL                                            | Extra Config                         |
| -------- | ---------------------------------------------- | ------------------------------------ |
| Jellyfin | `http://jellyfin.media.svc.cluster.local:8096` | Sync Movies + Shows libraries        |
| Plex     | `http://plex.media.svc.cluster.local:32400`    | Sync Movies + Shows libraries        |
| Radarr   | `http://radarr.media.svc.cluster.local:7878`   | Root folder: `/media/library/movies` |
| Sonarr   | `http://sonarr.media.svc.cluster.local:8989`   | Root folder: `/media/library/shows`  |

Each connection requires the respective API key and a quality profile selection. Connect either Jellyfin or Plex (or both) as media servers depending on your setup.
