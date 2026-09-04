# ROM Library & Steam Deck Sync

Remote management of the Steam Deck's EmuDeck ROM library from the workstation.
Two services in the `media` namespace, each doing one half of the job:

| Service   | URL                         | Port | Purpose                                              |
| --------- | --------------------------- | ---- | ---------------------------------------------------- |
| RomM      | `https://romm.m6o.dev`      | 8080 | ROM library manager — metadata, artwork, web play    |
| Syncthing | `https://syncthing.m6o.dev` | 8384 | Delivers the library to the Deck, backs its saves up |

```
workstation ──► RomM web UI ──┐
            └─► /mnt/nas/roms ┤   (NFS, drop files in directly)
                              ▼
        UNAS-4  /var/nfs/shared/ROMs
                              ▲
                      NFS     │
                     syncthing pod ──── NodePort 32000 ────┐
                                                           ▼
                              Steam Deck  ~/Emulation/roms   (receive only)
                                          ~/Emulation/saves  (send only)
```

## Delivery to the Deck

EmuDeck has no RomM client, so RomM does not reach the Deck itself. Syncthing carries
both directions instead — `library/roms` out to the Deck, the Deck's emulator saves
back to `deck/saves` — and is EmuDeck's own documented sync method.

## NAS share

Share `ROMs` on UNAS-4, exported to the three k3s nodes and to the workstation, at
`/var/nfs/shared/ROMs`. The NAS UI is not IaC-managed, so the share itself is created
by hand; the workstation mount is in
[`.config/etc.fstab`](../.config/etc.fstab) at `/mnt/nas/roms`.

Ownership matches the `Media` share: **`1000:988`, mode `770`** below the share root,
the root itself left as the NAS created it (`988:988`). uid 1000 is what the pods and
the workstation user both run as; gid 988 is the NAS's share group. `mkdir` on the NAS
runs as root, so the tree comes out `root:root 755` and must be corrected after:

```sh
ssh UNAS
mkdir -p /var/nfs/shared/ROMs/library/roms /var/nfs/shared/ROMs/library/bios /var/nfs/shared/ROMs/deck/saves
chown -R 1000:988 /var/nfs/shared/ROMs/library /var/nfs/shared/ROMs/deck
chmod -R 770 /var/nfs/shared/ROMs/library /var/nfs/shared/ROMs/deck
```

## Secret

`k3s/apps/media/romm/values.sops.yaml`:

```yaml
app-template:
  secrets:
    romm:
      stringData:
        ROMM_AUTH_SECRET_KEY: <openssl rand -hex 32>
        MARIADB_ROOT_PASSWORD: <random>
        DB_PASSWD: <random>
```

RomM calls the application database password `DB_PASSWD` and the MariaDB image calls
it `MARIADB_PASSWORD`; both names are fixed by their images. The secret stores the
value once under `DB_PASSWD` and `values.yaml` maps that key onto `MARIADB_PASSWORD`
for the sidecar, so the two can never drift into an access-denied loop.

Only the RomM container gets the secret wholesale via `envFrom`. MariaDB takes its two
variables by explicit `secretKeyRef`, so the database never holds
`ROMM_AUTH_SECRET_KEY` or the metadata provider keys.

Metadata providers are optional and can be added to the same file later without a
manifest change — RomM reads them as env vars: `IGDB_CLIENT_ID`,
`IGDB_CLIENT_SECRET`, `SCREENSCRAPER_USER`, `SCREENSCRAPER_PASSWORD`,
`STEAMGRIDDB_API_KEY`, `RETROACHIEVEMENTS_API_KEY`, `MOBYGAMES_API_KEY`. Hasheous is
enabled in `values.yaml` and needs no account, so scanning identifies most ROMs by
file hash before any provider is set up.

## RomM

Single pod, `Recreate` strategy (RWO PVCs), pinned to **k3s-node-01**:

| Container   | Image               | Role                                       |
| ----------- | ------------------- | ------------------------------------------ |
| mariadb     | `mariadb` (sidecar) | Database — PVC `romm-db-lh`                |
| wait-for-db | `busybox`           | Blocks RomM until 3306 is open             |
| romm        | `rommapp/romm`      | Python/nginx app + bundled Valkey on :8080 |

Valkey is baked into the RomM image and listens on `127.0.0.1:6379`, so there is no
cache container — it only needs `/redis-data` to persist. Everything RomM writes
outside the library (`resources/` artwork, `assets/` uploaded saves and states,
`config/config.yml`, and the Valkey dump) shares the single `romm-data-lh` volume via
`subPath`s. `config.yml` is a PVC and not a ConfigMap because RomM rewrites it when
platform bindings are changed in the UI.

`wait-for-db` probes TCP rather than running `mariadb-admin ping`, because the
MariaDB entrypoint bootstraps on a socket with `--skip-networking` — an open 3306
already means initialisation finished, and no credentials are needed.

Two Longhorn gotchas are handled in `values.yaml`: the MariaDB datadir is a `subPath`
so the volume's `lost+found` doesn't make `mariadb-install-db` refuse a non-empty
directory, and `fsGroup: 1000` with `fsGroupChangePolicy: OnRootMismatch` makes the
volumes writable for uid 1000 without a recursive chown of tens of thousands of
artwork files on every start.

### Library layout

RomM scans `/romm/library`, which is the `library/` subdir of the share. Platform
directory names must match RomM's slugs (`snes`, `gba`, `ps`, `n64`, …); the full
list is in RomM's Supported Platforms page, and a non-matching name can be remapped
via `system.platforms` in `config.yml`.

```
/var/nfs/shared/ROMs/
├── library/            ← RomM scan root
│   ├── roms/
│   │   ├── gba/
│   │   ├── snes/
│   │   └── ps/
│   └── bios/
│       ├── gba/
│       └── ps/
└── deck/
    └── saves/          ← EmuDeck saves, synced back from the Deck
```

`deck/` sits outside `library/` on purpose so RomM's scanner never sees it.

The ingress sets `proxy-body-size: "0"` — the 1 MB nginx default rejects ROM uploads
through the web UI outright, and disc images run to several GB.

## Syncthing

Single pod holding only the sync process, beside RomM on **k3s-node-01**. All folder
wiring lives in Syncthing's own config on `syncthing-config-lh`, not in the chart; the
chart mounts the whole ROMs share at `/nas`.

The GUI is a normal ingress on 8384. The sync protocol is a **NodePort on 32000**
(TCP + UDP/QUIC) because the Deck is on VLAN 10 and cannot reach a ClusterIP, and
MetalLB's pool is a single `/32` already held by ingress-nginx.

### Cluster-side folders

| Folder ID    | Path                | Type         |
| ------------ | ------------------- | ------------ |
| `roms`       | `/nas/library/roms` | Send Only    |
| `deck-saves` | `/nas/deck/saves`   | Receive Only |

Send Only on `roms` means the Deck can never delete something out of the library;
Receive Only on `deck-saves` makes it a pure one-way save backup. Promote
`deck-saves` to Send Receive only if a second device ever needs to restore from it.

> **Disable the filesystem watcher on both folders** (`fsWatcherEnabled: false`) and
> set `rescanIntervalS` to `3600`. Syncthing's watcher uses inotify, which never sees
> writes made by _other_ NFS clients — and every write here comes from another client
> (the RomM pod, or the workstation). Leaving the watcher on makes new ROMs appear to
> propagate at random, hours late. Periodic rescan is the only reliable trigger; drop
> the interval if faster pickup matters more than the NFS walk.

### Pairing

1. `https://syncthing.m6o.dev` → **Actions → Show ID**, copy the cluster device ID.
2. On the Deck, add that device and set its address explicitly to
   `tcp://10.10.50.10:32000, quic://10.10.50.10:32000`. Local discovery is broadcast-
   based and does not cross VLAN 10 → 50, so `dynamic` alone will only ever find the
   cluster through a public relay.
3. Accept the Deck on the cluster side, then share both folders with it.

## Steam Deck setup

1. **Developer Mode** — Settings → System → Enable Developer Mode.
2. **Decky Loader** — install per <https://decky.xyz/>.
3. **Syncthing** — install the **Syncthing GTK Flatpak** from Flathub, then the
   `decky-syncthing` plugin (`theCapypara/steamdeck-decky-syncthing`) and point it at
   the Flatpak.

   > Use the Flatpak, not the pacman/systemd install. SteamOS replaces all systemd
   > unit files on every update, so a systemd Syncthing has to be reconfigured after
   > each one. The Flatpak lives in `/home` and survives.

   The plugin proxies the GUI on `localhost:58384` and can start Syncthing with
   Gamescope or at boot.

4. **Deck-side folders** — mirror of the cluster side. Paths depend on where EmuDeck
   was installed:

| Folder ID    | SD card                                | Internal SSD                 | Type         |
| ------------ | -------------------------------------- | ---------------------------- | ------------ |
| `roms`       | `/run/media/mmcblk0p1/Emulation/roms`  | `/home/deck/Emulation/roms`  | Receive Only |
| `deck-saves` | `/run/media/mmcblk0p1/Emulation/saves` | `/home/deck/Emulation/saves` | Send Only    |

5. **Steam ROM Manager** — new ROMs are files, not Steam entries. Run SRM (desktop
   mode, or from gaming mode via the EmuDecky plugin) after a sync to add them as
   shortcuts.

### RetroAchievements

Each emulator authenticates to retroachievements.org itself. EmuDeck's Custom Mode
takes the login once and writes it into every emulator that supports it:

| Emulator         | Systems       | Note                                                      |
| ---------------- | ------------- | --------------------------------------------------------- |
| RetroArch        | 40+ via cores | The broadest coverage — most systems are reached this way |
| PCSX2            | PS2           |                                                           |
| DuckStation      | PS1           |                                                           |
| Dolphin          | GameCube, Wii | Needs _Enable Dual Core (speedup)_ **unchecked**          |
| PPSSPP           | PSP           | Native since 1.16                                         |
| Flycast          | Dreamcast     | Disable threaded rendering if save states are used        |
| melonDS, DeSmuME | DS            |                                                           |
| BizHawk          | BizHawk cores |                                                           |

**Hardcore mode** is the version that counts for site leaderboards; it disables save
states, cheats, fast-forward and most rewind features, and it is a per-emulator toggle.

Matching is by **ROM hash**, keyed to specific known-good dumps — the same property
Hasheous uses in RomM, so a library that scans cleanly generally matches here too.

`RETROACHIEVEMENTS_API_KEY` in `values.sops.yaml` makes RomM show per-game progress in
its own UI. It is read from the existing secret as a plain env var, so no manifest
change is needed.

### Syncing only some platforms

Syncthing has no per-file selection from the sending side; **ignore patterns are
per-device and live on the receiver**. To keep the Deck to a subset, set the
`roms` folder's ignore patterns on the _Deck_:

```
// keep these
!/gba
!/snes
!/ps
// drop everything else
/*
```

That is the right lever for the disc-based systems, where a handful of titles already
runs to tens of GB next to the Deck's Steam library.
