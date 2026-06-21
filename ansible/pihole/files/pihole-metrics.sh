#!/usr/bin/env bash
# Pi-hole HA metrics for the node_exporter textfile collector. Writes to a temp
# file in the same directory then renames, so node_exporter never reads a partial
# file. Run on a short systemd timer.
DIR=/var/lib/prometheus/node-exporter
TMP=$(mktemp "$DIR/pihole_ha.prom.XXXXXX")

dig +tries=1 +time=2 @127.0.0.1 pi.hole >/dev/null 2>&1 && dns_up=1 || dns_up=0
ip -4 addr show eth0 | grep -q 10.10.53.53 && v4=1 || v4=0
ip -6 addr show eth0 | grep -q 1c35::53 && v6=1 || v6=0
systemctl is-active --quiet keepalived && ka=1 || ka=0

cat > "$TMP" <<EOF
# HELP pihole_dns_up pihole-FTL answers a local DNS query (1=yes). Catches a bound-but-wedged FTL.
# TYPE pihole_dns_up gauge
pihole_dns_up $dns_up
# HELP pihole_holds_vip This node currently holds the keepalived VIP (1=yes).
# TYPE pihole_holds_vip gauge
pihole_holds_vip{family="ipv4"} $v4
pihole_holds_vip{family="ipv6"} $v6
# HELP pihole_keepalived_up keepalived service is active (1=yes).
# TYPE pihole_keepalived_up gauge
pihole_keepalived_up $ka
EOF

chmod 0644 "$TMP"
mv "$TMP" "$DIR/pihole_ha.prom"
