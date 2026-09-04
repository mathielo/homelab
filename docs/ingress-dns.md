# Ingress & DNS

How k3s services are accessed — from DNS resolution to TLS termination. Nothing is exposed to the public internet.

## Access Flow

```
Device (LAN or Tailscale)
  → Pi-hole resolves *.m6o.dev → 10.10.50.3        (split-DNS wildcard, MetalLB VIP)
  → MetalLB L2 routes to nginx ingress controller          (LoadBalancer service)
  → nginx ingress controller routes by hostname            (k3s, kube-extra namespace)
  → TLS terminated with Let's Encrypt certificate          (cert-manager + Cloudflare DNS-01)
  → Traffic forwarded to backend pod                       (ClusterIP service)
```

## Components

### 1. Split-DNS (Pi-hole)

Pi-hole has a wildcard dnsmasq record that resolves all `*.m6o.dev` hostnames to the MetalLB VIP:

```
# /etc/dnsmasq.d/20-k3s.conf (on Pi-hole)
address=/*.m6o.dev/10.10.50.3
```

The leading `*.` is load-bearing: it matches every subdomain at any depth but **not** the bare apex. `address=/m6o.dev/` (no `*.`) would also capture `m6o.dev` itself.

The VIP `10.10.50.3` is managed by MetalLB (L2 mode). No physical node uses this IP — k3s nodes start at `.10`. MetalLB responds to ARP requests for `.3` and routes traffic to the nginx ingress controller pod.

This record is loaded because Pi-hole v6 has `misc.etc_dnsmasq_d = true` (set by the Pi-hole Ansible playbook).

Only A/AAAA are intercepted. TXT, MX, NS and friends are always forwarded upstream, which is what lets cert-manager's DNS-01 self-check resolve `_acme-challenge` records through Pi-hole (see below).

#### Public names in the zone

`m6o.dev` is shared: the apex serves a public website on Cloudflare, and `r2.m6o.dev` is public too. The wildcard would swallow both, so they are excluded explicitly.

A public **subdomain** does need an explicit exclusion, since the wildcard matches it. One line each — dnsmasq picks the longest matching domain, and `#` means "use the normal upstream":

```
server=/r2.m6o.dev/#
```

There is **no public DNS record** for the homelab `*.m6o.dev` names — they only resolve for devices using Pi-hole as their DNS server:

- **LAN devices**: UniFi DHCP assigns Pi-hole (`10.10.53.53`) as the DNS server for all VLANs
- **Remote devices**: Tailscale global nameserver override points to Pi-hole (`100.100.53.53`)

The k3s server advertises `10.10.50.0/24` as a Tailscale subnet route, so remote tailnet devices can reach the VIP (`10.10.50.3`) even though it's a LAN IP.

### 2. Ingress Controller (nginx)

The nginx ingress controller runs in the `kube-extra` namespace and receives traffic on ports 80/443 via the MetalLB VIP (`10.10.50.3`). Each service defines an Ingress resource with its hostname:

```yaml
ingress:
  main:
    className: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
    hosts:
      - host: <app>.m6o.dev
        paths:
          - path: /
            service:
              identifier: main
    tls:
      - secretName: <app>-tls
        hosts:
          - <app>.m6o.dev
```

### 3. TLS Certificates (cert-manager + Cloudflare)

[cert-manager](https://cert-manager.io/) issues Let's Encrypt certificates using **DNS-01 challenges** via the Cloudflare API. This is the only role Cloudflare plays — it validates domain ownership by creating temporary DNS TXT records. No traffic is routed through Cloudflare.

| Component     | Details                                                        |
| ------------- | -------------------------------------------------------------- |
| ClusterIssuer | `letsencrypt-prod` (ACME, DNS-01 solver)                       |
| DNS provider  | Cloudflare (API token with `Edit zone DNS` permission)         |
| Secret        | `cloudflare-api-token` in `cert-manager` namespace (from SOPS) |
| Installed by  | `ansible/k3s/cert-manager.yaml` (jetstack Helm chart)          |

When a new Ingress with the `cert-manager.io/cluster-issuer` annotation is created, cert-manager automatically:

1. Requests a certificate from Let's Encrypt
2. Creates a `_acme-challenge.<domain>` TXT record in Cloudflare DNS
3. Let's Encrypt verifies the TXT record and issues the certificate
4. cert-manager stores the certificate in the specified TLS Secret
5. nginx ingress uses the Secret for TLS termination

Certificates renew automatically before expiry.

**DNS-01 self-check goes through Pi-hole.** Before asking Let's Encrypt to validate, cert-manager queries DNS itself to confirm the TXT record has propagated. By default it probes the domain's authoritative nameservers directly — but VLAN 50 (Servers) is blocked from reaching external DNS by the "Block ext DNS – Internal" firewall rule, so that probe times out and challenges hang in `pending`. The controller is pinned to Pi-hole for this check via `extraArgs` in `ansible/k3s/files/cert-manager.values.yaml`:

```yaml
extraArgs:
  - --dns01-recursive-nameservers=10.10.53.53:53
  - --dns01-recursive-nameservers-only=true
```

Unbound behind Pi-hole resolves the public `_acme-challenge` TXT recursively, so the check passes without opening external DNS egress on VLAN 50. If Pi-hole's IP or the DNS firewall rules change, update these args to match.

**A new certificate can sit `pending` for up to 30 minutes.** Because the self-check
goes through a recursive resolver rather than the authoritative nameservers, the first
probe — fired seconds after the TXT record is created — usually beats Cloudflare's own
propagation and gets an empty answer. That negative result is then cached for the
zone's SOA minimum, which Cloudflare sets to **1800 s**, and every retry until it
expires is answered from cache. The challenge clears itself once the entry ages out;
the ACME order stays valid far longer, so nothing is lost by waiting.

Deploying several services at once makes this visible — one certificate is issued in
about 90 s and the rest stall, purely on which name won the race.

**There are two caches, and pihole-FTL is the one that matters.** FTL keeps its own DNS
cache in front of Unbound, so Unbound can hold the correct answer while FTL still serves
the stale miss. Query both on the VIP holder to see which layer is stale:

```sh
dig +short TXT _acme-challenge.<name>.m6o.dev @127.0.0.1 -p 5335   # unbound
dig +short TXT _acme-challenge.<name>.m6o.dev @127.0.0.1 -p 53     # pihole-FTL
```

`unbound-control flush` does not touch FTL's cache. `reloaddns` flushes it without
restarting the DNS server, so it is cheap enough to reach for rather than waiting out
the TTL:

```sh
ssh pihole-01 'sudo pihole reloaddns'
```

A successful challenge deletes its TXT record at Cloudflare, but the positive answer
stays cached locally afterwards — so a name that resolves is not evidence the record
still exists, and comparing two services' `_acme-challenge` lookups says more about
cache state than about propagation. Query the authoritative nameserver from a host that
can reach it (`dig ... @amber.ns.cloudflare.com` on a Pi-hole) to see the real record.

## Adding a New Service

The wildcard DNS record covers all `*.m6o.dev` subdomains — no DNS changes needed. Just add an Ingress resource with the appropriate hostname and cert-manager annotation. See existing apps in `k3s/apps/` for examples.

The exception is a subdomain you want to stay **public** — see [Public names in the zone](#public-names-in-the-zone) above.
