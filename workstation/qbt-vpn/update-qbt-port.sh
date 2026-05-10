#!/bin/sh
# Push the current forwarded port to qBittorrent's WebUI API.
# Invoked inside the gluetun container by VPN_PORT_FORWARDING_UP_COMMAND
# whenever the forwarded port changes. Retries until qBt's WebUI is reachable.

set -eu

PORT_FILE="${VPN_PORT_FORWARDING_STATUS_FILE:-/tmp/gluetun/forwarded_port}"
PORT="$(cat "$PORT_FILE")"

until wget -qO- \
    --post-data "json={\"listen_port\":${PORT}}" \
    http://localhost:8080/api/v2/app/setPreferences >/dev/null; do
    sleep 15
done
