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

Music flow:
  DroppedNeedle (requests, discovery, import) → slskd (primary) / SABnzbd via Prowlarr (Usenet) → Plex (Plexamp)

Book flow:
  Shelfarr (requests, search, import) → Prowlarr → qbt-mam / SABnzbd → Audiobookshelf

Download flow:
  SABnzbd      → Gluetun VPN → Usenet provider  → NFS media library
  qBt (SE, BR, MAM) → Gluetun VPN → Torrent trackers → NFS media library
  slskd        → Gluetun VPN → Soulseek network → NFS media library

DNS/indexer flow:
  Prowlarr → DrunkenSlug / NZBFinder (NZB search)
  SABnzbd  → xsnews.nl (primary) / news.eweka.nl (secondary)
```

## Services

| Service        | URL                         | Port  | Purpose                                    |
| -------------- | --------------------------- | ----- | ------------------------------------------ |
| SABnzbd        | `https://sabnzbd.m6o.dev`   | 8080  | Usenet downloader                          |
| qBt SE         | `https://se.qbt.m6o.dev`    | 8080  | Torrent downloader                         |
| qBt BR         | `https://br.qbt.m6o.dev`    | 8080  | Torrent downloader                         |
| qBt MAM        | `https://mam.qbt.m6o.dev`   | 8080  | Torrent downloader (MyAnonaMouse, Simurg)  |
| slskd          | `https://slskd.m6o.dev`     | 5030  | Soulseek client                            |
| qui            | `https://qui.m6o.dev`       | 7476  | Multi-qBt instance manager UI + cross-seed |
| Prowlarr       | `https://prowlarr.m6o.dev`  | 9696  | Indexer manager/proxy                      |
| Radarr         | `https://radarr.m6o.dev`    | 7878  | Movie automation                           |
| Sonarr         | `https://sonarr.m6o.dev`    | 8989  | Shows automation                           |
| DroppedNeedle  | `https://dn.m6o.dev`        | 8688  | Music requests, discovery and import       |
| Shelfarr       | `https://shelfarr.m6o.dev`  | 80    | Book requests, search and import           |
| Bazarr         | `https://bazarr.m6o.dev`    | 6767  | Subtitle automation                        |
| Plex           | `https://plex.m6o.dev`      | 32400 | Media server / playback                    |
| Audiobookshelf | `https://books.m6o.dev`     | 13378 | Audiobook and ebook library / playback     |
| Autobrr        | `https://autobrr.m6o.dev`   | 7474  | Filtered release automation                |
| Pulsarr        | `https://pulsarr.m6o.dev`   | 3003  | Automated media requests (Sonarr/Radarr)   |
| Prismarr       | `https://prismarr.m6o.dev`  | 7070  | Media request portal                       |
| Profilarr      | `https://profilarr.m6o.dev` | 6868  | Quality profiles / custom formats          |

> Searcharr (Telegram request bot) also runs in `media` but has no web UI.

> RomM and Syncthing also run in `media` — the ROM library and its delivery to the Steam Deck. They are independent of the ARR/Usenet flow above; see [ROM Library & Steam Deck Sync](roms.md).

> Profilarr runs a bundled stateless `profilarr-parser` sidecar (in-pod, port 5000) that powers release-pattern testing; it has no web UI of its own.

> :exclamation: All URLs require Tailscale (or LAN) + Pi-hole DNS (`*.m6o.dev → 10.10.50.3`).

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
│   ├── movies/                  ← qBittorrent "nas/movies" category → Radarr imports from here
│   ├── shows/                   ← qBittorrent "nas/shows" category → Sonarr imports from here
│   ├── books/                   ← qBittorrent "nas/books" category → Shelfarr imports from here
│   ├── music/                   ← slskd completed downloads → DroppedNeedle imports from here
│   ├── held/                    ← DroppedNeedle downloads held for review (its /app/cache/held)
│   ├── parked/                  ← qBittorrent "nas/parked" category
│   ├── seeding/                 ← qBittorrent "nas/seeding" category
│   └── usenet/                  ← SABnzbd download root
└── lib/                         ← ARR apps hardlink here; media servers read here
    ├── movies/                  ← Radarr root folder, Plex movies library
    ├── shows/                   ← Sonarr root folder, Plex shows library
    ├── music/                   ← DroppedNeedle library, Plex music library, slskd share (read-only)
    ├── books/                   ← Shelfarr library (<Author>/<Title>/), Audiobookshelf library
    └── cartoons/ concerts/ musicvids/ yt/
```

### qBittorrent Categories → ARR Correlation

qBittorrent categories define the per-category save path. ARR download clients must be configured with the **matching category name** so Sonarr/Radarr can track and import only their own downloads.

| qBittorrent category | Save path          | ARR service | Download client category in ARR |
| -------------------- | ------------------ | ----------- | ------------------------------- |
| `nas/movies`         | `/media/dl/movies` | Radarr      | `nas/movies`                    |
| `nas/shows`          | `/media/dl/shows`  | Sonarr      | `nas/shows`                     |
| `nas/books`          | `/media/dl/books`  | Shelfarr    | `nas/books`                     |

Categories and per-instance preferences are managed declaratively via scripts in [scripts/qbt/](../scripts/qbt/): `apply-categories.sh <instance>` pushes that instance's block of [`categories.yaml`](../scripts/qbt/categories.yaml) (category → save path; each instance has its own set) and `apply-prefs.sh <instance>` pushes [`prefs.yaml`](../scripts/qbt/prefs.yaml), both through the WebUI API.

Categories prefixed `nas/` save to the NFS share, `r0/` to the DAS RAID0 on k3s-node-02.

> :bulb: qBittorrent persists categories to `/config/config/categories.json` on the Longhorn config PVC, so they survive pod restarts; the scripts are the source of truth and re-apply them to a fresh instance.

### Autobrr disk-space guard (DAS fill protection)

qBittorrent downloads land on the NVMe scratch (`/local/_incomplete`) and only **move to the DAS (`/r0`) on completion**. So a full DAS doesn't fail downloads — it fails the post-completion _move_, stranding finished torrents in `_incomplete` (logged as `Failed to move torrent`). To stop new grabs before that happens, autobrr runs [`disk-guard.sh`](../k3s/apps/media/autobrr/values.yaml) (a ConfigMap-mounted script at `/scripts/disk-guard.sh`) as an External **Exec** check.

- autobrr is pinned to `k3s-node-02` (where the DAS and the qbt-\* instances live) with `/mnt/r0` mounted read-only
- **Exit 0** while free space ≥ threshold, else **exit 1**.

## VPN Kill-Switch (Gluetun)

SABnzbd, qBittorrent and slskd all run behind a Gluetun VPN sidecar for privacy:

- **VPN provider:** ProtonVPN (WireGuard)
- **Server locations:** Sweden (`qbt-se`, SABnzbd, slskd), Brazil (`qbt-br`), and a fixed single-ASN set of Sweden servers (`qbt-mam`) — one WireGuard profile per exit
- **Port forwarding:** qBittorrent and slskd get a ProtonVPN NAT-PMP port. Gluetun pushes it to qBittorrent's API; slskd polls Gluetun's control server itself and disconnects from Soulseek while the tunnel is down
- **Kill-switch:** If the VPN tunnel drops, all download traffic is blocked (Gluetun firewall)
- **Bypass subnets:** `10.42.0.0/16` and `10.43.0.0/16` (k3s pod/service CIDRs) so in-cluster communication still works

Credentials (`WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`) are encrypted per instance in `values.sops.yaml`.

### Restarting a qBittorrent instance

A `preStop` hook stops every torrent (`hashes=all`) before the pod terminates, so libtorrent flushes fastresume to disk instead of losing progress. The matching resume on startup is **deliberately not wired up** — a bulk `torrents/start` re-announces the whole library at once — so **torrents come back stopped and resuming them is a manual step**. On `qbt-mam` that is ~2000 torrents reading `stoppedUP` with 0 leechers, which looks like a failed rollout and is not one.

The hook's `sleep 5` is a fixed window, so a large library only partially stops before SIGTERM; the remainder come back seeding. A post-restart split like 1955 stopped / 233 seeding is that race, not selective breakage.

### MyAnonaMouse dynamic seedbox (qbt-mam)

MAM gates download/announce permission on the requesting IP via an ASN-locked session. To keep that lock matched, `qbt-mam` is a dedicated instance pinned to a fixed set of Stockholm ProtonVPN servers. A `mam` sidecar calls [`dynamicSeedbox`](https://www.myanonamouse.net/api/endpoint.php/3/json/dynamicSeedbox.php) hourly to keep the seedbox IP current.

- **Seedbox session:** MAM **Preferences → Security** → "Allow session to set dynamic seedbox IP", then ASN-lock it (after the first successful call registers the right ASN). Separate from the browser session. Its `mam_id` is stored as `MAM_ID` in `values-mam.sops.yaml` and seeds a cookie jar at `/config/mam/cookies.txt`.
- **`MAM_ID` is single-use.** MAM rotates the `mam_id` on every accepted call and invalidates the previous one, so the cookie jar on the `qbt-mam-config-lh` PVC is the live credential and `MAM_ID` is only a bootstrap that is spent the first time it works. Once the jar is lost, no restart or redeploy recovers the session — the sidecar logs `Invalid session - Other` forever and the only fix is a new `mam_id` from Preferences → Security.
- **Announces outlive the updater.** The lock is on the ASN, not the IP, so seeding keeps working on a stale seedbox IP as long as Gluetun stays inside the pinned ASNs (AS212238, AS208172). A dead updater is therefore silent: the first symptom is MAM's tracker-error list, not qBittorrent. Check `kubectl -n media logs deploy/qbt-mam -c mam --tail=5` for `"Success":true` after any qbt-mam restart.
- **429 is not a rejection.** A restart within an hour of a successful IP change draws `Last change too recent` (rate limit: 1 change/hour, rolling). The cookie jar is still valid — the sidecar waits out the window rather than discarding it.

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

| Setting                   | Path               |
| ------------------------- | ------------------ |
| Temporary Download Folder | `/incomplete`      |
| Completed Download Folder | `/media/dl/usenet` |

**Config → Categories** (folders are relative to the completed download folder):

| Category | Folder   |
| -------- | -------- |
| `movies` | `movies` |
| `shows`  | `shows`  |
| `music`  | `music`  |
| `books`  | `books`  |

Note the **API key** from Config → General → Security.

### Step 2: qui + qBittorrent instances

Instances config and categories are managed via scripts in [scripts/qbt/](../scripts/qbt/).

Note the **WebUI credentials** — password is managed in `values.sops.yaml`.

qui cross-seeds in hardlink mode into `/r0/cross-seed/<tracker>` on qbt-se and qbt-br. Its cross-seed settings live in qui's database, not in this repo:

| Setting                         | Value |
| ------------------------------- | ----- |
| Skip recheck                    | on    |
| Max auto-start download (MiB)   | 0     |

**Skip recheck** must stay on. qui's hardlink adds inherit qBittorrent's incomplete-download path (`/local/_incomplete`), so any cross-seed that rechecks below 100% is moved off `/r0` the moment the recheck ends. That turns its hardlinks into copies, and two partial adds with the same root folder name collide in the temp path. With Skip recheck on, qui only adds a match whose files all hardlink, so every cross-seed is complete on arrival and never leaves `/r0`.

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

> :bulb: Plex is pinned to `k3s-node-02` (M70q Gen 5) via hostname nodeSelector for its Intel i5-14500T iGPU (Quick Sync). The pin is required, not a preference — see `k3s/apps/media/plex/values.yaml`.

Complete the setup wizard at `https://plex.m6o.dev`, then:

1. **Claim server** — should auto-claim via `PLEX_CLAIM` env var on first boot. If the token expired, generate a new one at `https://plex.tv/claim`, re-encrypt `values.sops.yaml`, and redeploy.

2. **Add libraries:**

| Library      | Content Type | Folder                 |
| ------------ | ------------ | ---------------------- |
| Movies       | Movies       | `/media/lib/movies`    |
| Shows        | TV Shows     | `/media/lib/shows`     |
| Cartoons     | TV Shows     | `/media/lib/cartoons`  |
| Concerts     | Other Videos | `/media/lib/concerts`  |
| Music Videos | Other Videos | `/media/lib/musicvids` |
| YouTube      | Other Videos | `/media/lib/yt`        |
| Music        | Music        | `/media/lib/music`     |

NFS writes from other pods raise no filesystem events in Plex, so new files appear on the scheduled library scan (Settings → Library → "Scan my library periodically", every 2 hours).

3. **Enable hardware transcoding** (requires Plex Pass):
   - Settings → Transcoder → check "Use hardware acceleration when available"
   - Intel Quick Sync is passed through via the `gpu.intel.com/i915` resource request

4. **Turn off "Backup database"** — Settings → Manage → Scheduled Tasks.
   It writes a dated copy of both SQLite databases into
   `Plug-in Support/Databases/` every 3 days and retains several, so ~1.3 GB of the
   `plex-config-lh` volume is Plex backing itself up inside the volume Longhorn already
   backs up nightly to 14 dailies / 8 weeklies / 6 monthlies. Each new copy is ~346 MB
   of fresh blocks in that night's Longhorn delta, and the volume is the one that
   actually stalls the NAS (see [`storage-longhorn.md`](storage-longhorn.md) →
   "Backup target errors"). Delete the existing `*.db-YYYY-MM-DD` copies after
   unchecking it.

5. **Get API token** for Homepage widget:
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

Browse `https://profilarr.m6o.dev` and create the admin account (built-in auth is on). Then:

1. **Settings → Arr** — add Sonarr and Radarr:

   | Setting | Sonarr                                       | Radarr                                       |
   | ------- | -------------------------------------------- | -------------------------------------------- |
   | URL     | `http://sonarr.media.svc.cluster.local:8989` | `http://radarr.media.svc.cluster.local:7878` |
   | API Key | Sonarr API key                               | Radarr API key                               |

2. **Database** — import a profile database (e.g. the Dictionarry database), then select or build the quality profiles / custom formats you want.
3. **Sync** — push the selected profiles to Sonarr/Radarr. The in-pod `profilarr-parser` sidecar powers the release-regex testing used when building/validating formats.

> :bulb: Profilarr stores its config and the \*arr API keys in its own `/config` (Longhorn `profilarr-config-lh` PVC) — no `values.sops.yaml` is required.

### Step 11: slskd

slskd is configured through environment variables; `k3s/apps/media/slskd/values.sops.yaml` holds:

| Key                                           | Value                                                                 |
| --------------------------------------------- | --------------------------------------------------------------------- |
| `WIREGUARD_PRIVATE_KEY`                       | ProtonVPN WireGuard config with NAT-PMP (port forwarding) enabled     |
| `WIREGUARD_ADDRESSES`                         | Same config                                                           |
| `SLSKD_SLSK_USERNAME` / `SLSKD_SLSK_PASSWORD` | Soulseek account (registered on first login with an unused name)      |
| `SLSKD_USERNAME` / `SLSKD_PASSWORD`           | slskd web UI login                                                    |
| `SLSKD_API_KEY`                               | `role=readwrite;cidr=10.42.0.0/16;<key>` — the key DroppedNeedle uses |

The first two sit under `app-template.controllers.slskd.initContainers.gluetun.env`, the rest under `app-template.controllers.slskd.containers.slskd.env`.

Incomplete transfers live on `k3s-node-01`'s SSD (`/mnt/ssd/local/slskd`); finished files are moved to `/media/dl/music`. The shared folder is `/media/lib/music`, mounted read-only and rescanned every 6 hours (System → Shares → Rescan picks up new imports immediately). The System page at `https://slskd.m6o.dev` shows the VPN state and the forwarded listen port.

### Step 12: DroppedNeedle

Browse `https://dn.m6o.dev` — the first account created is the admin. Then:

1. **Settings → Library** — library path `/media/lib/music`, then run a scan.

2. **Settings → Download Client:**

   | Setting         | Value                                         |
   | --------------- | --------------------------------------------- |
   | slskd URL       | `http://slskd.media.svc.cluster.local:5030`   |
   | slskd API key   | The key from `SLSKD_API_KEY`                  |
   | SABnzbd URL     | `http://sabnzbd.media.svc.cluster.local:8080` |
   | SABnzbd API key | SABnzbd API key (Step 1), category `music`    |
   | Source priority | slskd first, Usenet second                    |

3. **Settings → Indexers / Prowlarr** — `http://prowlarr.media.svc.cluster.local:9696` + Prowlarr API key.

4. **Settings → Plex** — `http://plex.media.svc.cluster.local:32400` + Plex token (Step 7), Music library.

5. **AcoustID** — a free API key from `https://acoustid.org` enables fingerprint verification; without it, matching relies on tags and text.

Plexamp plays the library through Plex; DroppedNeedle's Plex login lets Plex users sign in and request.

### Step 13: Audiobookshelf

Browse `https://books.m6o.dev` — the first account created is the root admin. Then:

1. **Settings → Libraries → Add** — media type **Books**, folder `/media/lib/books`. One library holds both formats: an ebook and an audiobook in the same `<Author>/<Title>/` folder are one item, with reading and listening progress tracked separately.

2. **Settings → API Keys** — create a key for Shelfarr. The library ID is the last segment of the library's URL.

Library files are hardlinks to torrents that are still seeding, so an in-place write breaks the torrent's piece hashes. Leave **Store metadata with item** off (metadata and covers then live under `/metadata` on the Longhorn volume) and don't run the **Embed Metadata** tool.

### Step 14: Shelfarr

Browse `https://shelfarr.m6o.dev` — the first account created is the admin. Then, under **Admin → Settings**:

| Setting             | Value                                                                            |
| ------------------- | -------------------------------------------------------------------------------- |
| Indexer             | Prowlarr, `https://prowlarr.m6o.dev` + API key, tags `books`                     |
| Import mode         | `hardlink`                                                                       |
| Audiobook output    | `/media/lib/books`, path template `{author}/{title}`                             |
| Ebook output        | `/media/lib/books`, path template `{author}/{title}`                             |
| Download paths      | local `/media/dl`, remote empty                                                  |
| Audiobookshelf      | `http://audiobookshelf.media.svc.cluster.local:13378` + API key (Step 13)        |
| ABS library IDs     | The Books library's ID for both the audiobook and the ebook library              |

Download clients have their own page, **Admin → Download Clients** (linked from the admin dashboard, not from Settings):

| Client      | Value                                                                              | Download path            |
| ----------- | ---------------------------------------------------------------------------------- | ------------------------ |
| qBittorrent | `http://qbt-mam.media.svc.cluster.local:8080` + WebUI login, category `nas/books`  | `/media/dl/books`        |
| SABnzbd     | `http://sabnzbd.media.svc.cluster.local:8080` + API key (Step 1), category `books` | `/media/dl/usenet/books` |

Shelfarr only imports from paths under its local download path or a client's download path, and treats each client's path as a shared root it never deletes — without them, finished downloads are refused and SABnzbd job cleanup has no floor.

Every book torrent goes to `qbt-mam` because MAM's session is ASN-locked to that instance's VPN exit (see [MyAnonaMouse dynamic seedbox](#myanonamouse-dynamic-seedbox-qbt-mam)). Both output paths share one template so an ebook and its audiobook land in the same folder, which is what makes them a single Audiobookshelf item.
