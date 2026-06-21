#!/usr/bin/env bash
# keepalived health check. Pi-hole is healthy only if pihole-FTL actually ANSWERS
# a query — a TCP connect to :53 succeeds against a bound-but-wedged FTL (the
# kernel completes the handshake even when FTL never replies), so a connect check
# would hand the VIP to a dead resolver. Query pi.hole, which FTL answers locally
# (no upstream needed), so the check is independent of Unbound/internet.
pgrep -x pihole-FTL >/dev/null || exit 1
dig +tries=1 +time=2 @127.0.0.1 pi.hole >/dev/null 2>&1 || exit 1
exit 0
