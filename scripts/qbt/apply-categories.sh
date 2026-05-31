#!/usr/bin/env bash
# Create categories from scripts/qbt/categories.yaml on a qBittorrent instance.
# Idempotent: createCategory 409s if the category exists, so we fall back to
# editCategory to update its save path (categories.yaml is the source of truth).
# Requires: yq (mikefarah, Go) — installed via scripts/install.sh
#
# Usage: scripts/qbt/apply-categories.sh <instance>
#   instance = qbt-br | qbt-se | all

set -euo pipefail

CATS_FILE="$(dirname "$0")/categories.yaml"

case "${1:-}" in
    "")            echo "Usage: $0 <qbt-br|qbt-se|all>"; exit 2 ;;
    all)           INSTANCES=(qbt-br qbt-se) ;;
    qbt-br|qbt-se) INSTANCES=("$1") ;;
    *)             echo "Unknown instance: $1 (allowed: qbt-br, qbt-se, all)"; exit 2 ;;
esac

for inst in "${INSTANCES[@]}"; do
    yq -o=json '.' "$CATS_FILE" | jq -r 'to_entries[] | "\(.key)\t\(.value.save_path)"' \
    | while IFS=$'\t' read -r cat save_path; do
        if kubectl -n media exec "deploy/${inst}" -c main -- \
            wget -qO- --post-data="category=${cat}&savePath=${save_path}" \
            http://localhost:8080/api/v2/torrents/createCategory; then
            echo "  created ${cat} -> ${save_path}"
        elif kubectl -n media exec "deploy/${inst}" -c main -- \
            wget -qO- --post-data="category=${cat}&savePath=${save_path}" \
            http://localhost:8080/api/v2/torrents/editCategory; then
            echo "  updated ${cat} -> ${save_path}"
        else
            echo "  FAILED ${cat} -> ${save_path}" >&2
        fi
    done
    echo "applied categories to ${inst}"
done
