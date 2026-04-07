#!/usr/bin/env bash
# pihole-upgrade.sh — Safe Pi-hole upgrade that handles Tailscale DNS conflict
#
# Problem: Pi-hole restarts during upgrade, breaking the circular DNS path:
#   resolv.conf → Tailscale (100.100.100.100) → Pi-hole (100.100.53.53) → dead
# Solution: Temporarily stop Tailscale so the host resolves via Unbound directly.
#
# Managed by Ansible — do not edit on the host directly.

set -euo pipefail

UNBOUND_ADDR="127.0.0.1"
UNBOUND_PORT=5335
FALLBACK_DNS="9.9.9.9"

# Expected Pi-hole settings (source of truth: ansible/pihole/pihole.yaml)
EXPECTED_UPSTREAMS='["127.0.0.1#5335"]'
EXPECTED_DNSMASQ_D="true"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "ERROR: $*"; exit 1; }

# Must run as root (pihole-FTL --config, systemctl, resolv.conf)
[[ $EUID -eq 0 ]] || die "Run with sudo"

# --- Pre-flight checks ---

log "Checking Unbound is running..."
dig @"$UNBOUND_ADDR" -p "$UNBOUND_PORT" github.com +short +time=3 >/dev/null 2>&1 \
    || die "Unbound is not resolving on $UNBOUND_ADDR:$UNBOUND_PORT — fix Unbound first"

# --- Stop Tailscale to break circular DNS dependency ---

TAILSCALE_WAS_RUNNING=false
if systemctl is-active --quiet tailscaled; then
    TAILSCALE_WAS_RUNNING=true
    log "Stopping Tailscale..."
    systemctl stop tailscaled

    # Tailscale managed resolv.conf — replace with temporary fallback
    log "Setting temporary DNS to $FALLBACK_DNS..."
    echo "nameserver $FALLBACK_DNS" > /etc/resolv.conf
fi

# --- Ensure cleanup on exit ---

cleanup() {
    if [[ "$TAILSCALE_WAS_RUNNING" == "true" ]]; then
        log "Restarting Tailscale..."
        systemctl start tailscaled
        # Tailscale will reclaim /etc/resolv.conf automatically
        sleep 2
        log "Tailscale restored (resolv.conf will be reclaimed)"
    fi
}
trap cleanup EXIT

# --- Run the upgrade ---

log "Starting Pi-hole upgrade..."
pihole -up

# --- Verify and restore critical settings ---

log "Verifying Pi-hole configuration..."

CURRENT_UPSTREAMS=$(pihole-FTL --config dns.upstreams 2>/dev/null || echo "")
if [[ "$CURRENT_UPSTREAMS" != *"127.0.0.1#5335"* ]]; then
    log "FIXING: dns.upstreams was reset — restoring Unbound"
    pihole-FTL --config dns.upstreams "$EXPECTED_UPSTREAMS"
fi

CURRENT_DNSMASQ_D=$(pihole-FTL --config misc.etc_dnsmasq_d 2>/dev/null || echo "")
if [[ "$CURRENT_DNSMASQ_D" != *"true"* ]]; then
    log "FIXING: misc.etc_dnsmasq_d was reset — re-enabling"
    pihole-FTL --config misc.etc_dnsmasq_d "$EXPECTED_DNSMASQ_D"
fi

# Verify Unbound is still reachable through Pi-hole
log "Verifying DNS resolution through Pi-hole..."
if dig @127.0.0.1 github.com +short +time=5 >/dev/null 2>&1; then
    log "DNS resolution OK"
else
    log "WARNING: Pi-hole DNS not resolving — run the Ansible playbook to restore full config"
    log "  ansible-playbook pihole/pihole.yaml"
fi

log "Upgrade complete"
