# Tools

More like "services", but using namespace `tools` to not conflict with k8s names. This namespace hosts miscellaneous tools and services for end-users.

## Services

| Service | URL                   | Port | Purpose                              |
| ------- | --------------------- | ---- | ------------------------------------ |
| SearXNG | `https://srx.m6o.dev` | 8080 | Privacy-respecting metasearch engine |

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
