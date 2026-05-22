#!/usr/bin/env bash
# Apply scripts/qbt/prefs.yaml to a qBittorrent instance via the WebUI API.
# Relies on qBt's localhost auth bypass — no creds needed.
# Requires: yq (mikefarah, Go) — installed via scripts/install.sh
#
# Usage: scripts/qbt/apply-prefs.sh <instance>
#   instance = qbt-br | qbt-se | all

set -euo pipefail

PREFS_FILE="$(dirname "$0")/prefs.yaml"

case "${1:-}" in
    "")            echo "Usage: $0 <qbt-br|qbt-se|all>"; exit 2 ;;
    all)           INSTANCES=(qbt-br qbt-se) ;;
    qbt-br|qbt-se) INSTANCES=("$1") ;;
    *)             echo "Unknown instance: $1 (allowed: qbt-br, qbt-se, all)"; exit 2 ;;
esac

ENCODED="$(yq -o=json -I=0 '.' "$PREFS_FILE" | jq -sRr @uri)"

for inst in "${INSTANCES[@]}"; do
    kubectl -n media exec "deploy/${inst}" -c main -- \
        wget -qO- --post-data="json=${ENCODED}" \
        http://localhost:8080/api/v2/app/setPreferences
    echo "applied prefs to ${inst}"
done
