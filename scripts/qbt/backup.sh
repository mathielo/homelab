#!/usr/bin/env bash
# Backs up qBittorrent config files from the running pod.
# Output: YYYYMMDD-HHMM-qbittorrent-config.zip in the current directory.

set -euo pipefail

NAMESPACE="media"
LABEL_SELECTOR="app.kubernetes.io/name=qbittorrent"
TIMESTAMP=$(date +%Y%m%d-%H%M)
ARCHIVE="${TIMESTAMP}-qbittorrent-config.zip"
TMPDIR=$(mktemp -d)

POD=$(kubectl get pod -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[0].metadata.name}')
echo "Backing up from pod: $POD"

kubectl cp -n "$NAMESPACE" -c qbittorrent "${POD}:/config/config" "$TMPDIR/config"
kubectl cp -n "$NAMESPACE" -c qbittorrent "${POD}:/config/data/BT_backup" "$TMPDIR/BT_backup"

(cd "$TMPDIR" && zip -r "$OLDPWD/$ARCHIVE" .)
rm -rf "$TMPDIR"

echo "Backup saved: $ARCHIVE"
