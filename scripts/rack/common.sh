#!/usr/bin/env bash
# Shared setup + helpers for the rack power scripts (scripts/rack/shutdown,
# scripts/rack/startup). Sourced by them — not run directly.

set -euo pipefail

# SSH options: don't hang on unreachable hosts.
SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes"

# k3s nodes, server split from agents so each script orders them by intent:
# shutdown powers agents off first; startup brings the server up first.
K3S_SERVER="k3s-server"
K3S_AGENTS=("k3s-node-01" "k3s-node-02")

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $*" >&2; }

run_ssh() {
    local host="$1"
    shift
    ssh $SSH_OPTS "$host" "$@"
}
