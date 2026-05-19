#!/usr/bin/env bash
#
# Gracefully shuts down all devices on the homelab rack.
# Uses SSH hosts defined in ~/.ssh/config (sourced from .config/ssh.config).
#
# Shutdown order:
#   1. UNVR-I (fire and forget)
#   2. Home Assistant Pi (fire and forget)
#   3. Shut down k3s nodes (agents first, then server)
#   4. Pi-hole (last — it's DNS for everything)
#
# Usage: ./scripts/rack-shutdown.sh [--dry-run]

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# SSH options: don't hang on unreachable hosts
SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes"

# --- Helpers ---

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $*" >&2; }

run_ssh() {
    local host="$1"
    shift
    if $DRY_RUN; then
        log "[DRY-RUN] ssh $SSH_OPTS $host $*"
    else
        ssh $SSH_OPTS "$host" "$@"
    fi
}

wait_for_shutdown() {
    local host="$1"
    local max_wait=60
    local elapsed=0
    log "Waiting for $host to go offline..."
    while [ $elapsed -lt $max_wait ]; do
        if ! ssh $SSH_OPTS -o ConnectTimeout=2 "$host" "true" 2>/dev/null; then
            log "$host is offline."
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    warn "$host still reachable after ${max_wait}s — continuing anyway."
}

# --- Step 1: UNVR-I (fire and forget) ---

# log "=== Step 1: Shutting down UNVR-I ==="
# run_ssh UNVR "poweroff" || warn "Failed to send shutdown to UNVR"

# --- Step 2: Home Assistant Pi (fire and forget) ---

log "=== Step 2: Shutting down Home Assistant ==="
run_ssh homeassistant "sudo shutdown -h now" || warn "Failed to send shutdown to homeassistant"

# --- Step 3: Shut down k3s nodes ---
# No drain/cordon — pods terminate naturally on shutdown,
# and skipping drain avoids leftover SchedulingDisabled state on next boot.

K3S_NODES=("k3s-node-01" "k3s-node-02" "k3s-server")  # agents first, then server

log "=== Step 3: Shutting down k3s nodes ==="
for node in "${K3S_NODES[@]}"; do
    log "Shutting down $node..."
    run_ssh "$node" "sudo shutdown -h now" || warn "Failed to send shutdown to $node"
    if ! $DRY_RUN; then
        wait_for_shutdown "$node"
    fi
done

# --- Step 4: Pi-hole (last — DNS for the whole network) ---

log "=== Step 4: Shutting down Pi-hole ==="
run_ssh pihole "sudo shutdown -h now" || warn "Failed to send shutdown to pihole"

log "=== Rack shutdown complete ==="
log "Safe to disconnect power."
