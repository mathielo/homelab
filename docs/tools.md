# Tools

More like "services", but using namespace `tools` to not conflict with k8s names. This namespace hosts miscellaneous tools and services for end-users.

## Services

| Service    | URL                    | Port | Purpose                              |
| ---------- | ---------------------- | ---- | ------------------------------------ |
| SearXNG    | `https://srx.m6o.dev`  | 8080 | Privacy-respecting metasearch engine |
| Sure       | `https://sure.m6o.dev` | 3000 | Personal finance app                 |
| The Lounge | `https://irc.m6o.dev`  | 9000 | Self-hosted web IRC client           |

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

## Sure

Single pod, four containers, `Recreate` strategy (RWO PVCs):

| Container | Image                     | Role                                  |
| --------- | ------------------------- | ------------------------------------- |
| postgres  | `postgres` (sidecar)      | Database — PVC `sure-postgres-lh`     |
| redis     | `valkey/valkey` (sidecar) | Sidekiq queue / cache — ephemeral     |
| web       | `ghcr.io/we-promise/sure` | Rails app on `:3000`                  |
| worker    | `ghcr.io/we-promise/sure` | `bundle exec sidekiq` background jobs |

A `wait-for-db` initContainer blocks the app containers until Postgres accepts
connections. `web` and `worker` share the `sure-storage-lh` PVC at `/rails/storage`
(Active Storage uploads/imports). DB migrations run from the image entrypoint on
boot. `PGDATA` is a subdirectory so the Longhorn volume's `lost+found` doesn't make
`initdb` refuse a non-empty data directory.

## The Lounge

Single pod running as `node` (1000:1000); `fsGroup: 1000` makes the
`thelounge-data-lh` PVC writable. Private (bouncer) mode — it holds persistent IRC
connections and per-user scrollback.

- `config.js` ships as a ConfigMap mounted **read-only** at
  `/var/opt/thelounge/config.js` (server config only, no secrets). `reverseProxy:
  true` makes it trust nginx's `X-Forwarded-*` headers behind the ingress.
- Everything else (`users/`, sqlite history, logs) lives on the PVC at
  `THELOUNGE_HOME=/var/opt/thelounge`.
- **Accounts are imperative** — private mode has no signup. Create users with:
  ```
  kubectl exec -it -n tools deploy/thelounge -- thelounge add <username>
  ```
  The account persists on the PVC; this is the one manual step after first deploy.
