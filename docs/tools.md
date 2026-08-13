# Tools

More like "services", but using namespace `tools` to not conflict with k8s names. This namespace hosts miscellaneous tools and services for end-users.

## Services

| Service  | URL                        | Port | Purpose                              |
| -------- | -------------------------- | ---- | ------------------------------------ |
| SearXNG  | `https://srx.m6o.dev`      | 8080 | Privacy-respecting metasearch engine |
| Miniflux | `https://miniflux.m6o.dev` | 8080 | Minimalist RSS/feed reader           |

## SearXNG

Single pod: the `searxng` container plus an `init-settings` initContainer.

- `settings.yml` ships as a ConfigMap with a `__SECRET_KEY__` placeholder. The
  initContainer copies it into a writable emptyDir and `sed`-replaces the
  placeholder with `$SEARXNG_SECRET` (from sops) before the app reads it — so no
  secret ever lands in the ConfigMap.
- The image runs as uid/gid `977`; `fsGroup: 977` makes the emptyDir writable. The
  startup `"/etc/searxng" is not owned by searxng:searxng` line is a cosmetic
  warning.
- **No Valkey.** Its only role is the limiter / bot-protection, which only matters
  for public instances. JSON output is disabled (`search.formats: [html]`); add
  `json` if a local-AI/RAG backend ever needs it (a `format=json` request returns
  403 until then).

## Miniflux

Single pod, two containers, `Recreate` strategy (RWO PVC):

| Container | Image                  | Role                                   |
| --------- | ---------------------- | -------------------------------------- |
| postgres  | `postgres` (sidecar)   | Database — PVC `miniflux-postgres-lh`  |
| app       | `miniflux/miniflux`    | Go web app on `:8080`                  |

All feed/entry/icon state lives in Postgres, so there is no separate app PVC. A
`wait-for-db` initContainer blocks the app until Postgres accepts connections.
`DATABASE_URL` uses the Postgres superuser (default `POSTGRES_USER`) so Miniflux's
migrations (`RUN_MIGRATIONS=1`) can `CREATE EXTENSION hstore`. `PORT=8080` rebinds
the default `127.0.0.1:8080` listener to `0.0.0.0` so the Service can reach it. The
admin account is bootstrapped once via `CREATE_ADMIN=1` / `ADMIN_USERNAME` /
`ADMIN_PASSWORD`. `PGDATA` is a subdirectory so the Longhorn volume's `lost+found`
doesn't make `initdb` refuse a non-empty data directory.
