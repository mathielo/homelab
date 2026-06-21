#!/usr/bin/env bash
# keepalived health check. Healthy only if pihole-FTL is running AND accepting
# DNS on TCP/53 — a bare process check would keep the VIP on a box whose
# resolver has wedged. Uses bash /dev/tcp to avoid a dig dependency.
pgrep -x pihole-FTL >/dev/null || exit 1
exec 3<>/dev/tcp/127.0.0.1/53 || exit 1
exec 3>&- 3<&-
exit 0
