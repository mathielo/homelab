#!/usr/bin/env bash
#
# Download a YouTube video at the best available quality (up to 4K) and
# merge it into a single MKV. Reuses the yt-dlp + ffmpeg binaries that
# Open Video Downloader already bundles, so there's nothing extra to install.
#
# The OVD GUI caps its quality dropdown at 1080p (it only lists formats that
# have an H.264 video stream, and YouTube serves 1440p/2160p as VP9 only).
# This script bypasses that by selecting the best video+audio directly.
#
# Usage: ./scripts/yt-dl.sh <url> [extra yt-dlp args]

set -euo pipefail

OVD_BIN="$HOME/.local/share/com.jelleglebbeek.youtube-dl-gui/bin"

"$OVD_BIN/yt-dlp" \
    -f "bv*[height<=2160]+ba/b" \
    --merge-output-format mkv \
    --ffmpeg-location "$OVD_BIN" \
    -o "%(title)s.%(ext)s" \
    "$@"
