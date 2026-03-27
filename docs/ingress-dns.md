# Ingress & DNS

How k3s services are accessed — from DNS resolution to TLS termination. Nothing is exposed to the public internet.

## Access Flow

```
Device (LAN or Tailscale)
  → Pi-hole resolves *.hl.mathielo.com → 10.10.50.3        (split-DNS wildcard, MetalLB VIP)
  → MetalLB L2 routes to nginx ingress controller          (LoadBalancer service)
  → nginx ingress controller routes by hostname            (k3s, kube-extra namespace)
  → TLS terminated with Let's Encrypt certificate          (cert-manager + Cloudflare DNS-01)
  → Traffic forwarded to backend pod                       (ClusterIP service)
```

## Components

### 1. Split-DNS (Pi-hole)

Pi-hole has a wildcard dnsmasq record that resolves all `*.hl.mathielo.com` hostnames to the MetalLB VIP:

```
# /etc/dnsmasq.d/20-k3s.conf (on Pi-hole)
address=/hl.mathielo.com/10.10.50.3
```

The VIP `10.10.50.3` is managed by MetalLB (L2 mode). No physical node uses this IP — k3s nodes start at `.10`. MetalLB responds to ARP requests for `.3` and routes traffic to the nginx ingress controller pod.

This record is loaded because Pi-hole v6 has `misc.etc_dnsmasq_d = true` (set by the Pi-hole Ansible playbook).

There is **no public DNS record** for `*.hl.mathielo.com` — it only resolves for devices using Pi-hole as their DNS server:

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
      - host: <app>.hl.mathielo.com
        paths:
          - path: /
            service:
              identifier: main
    tls:
      - secretName: <app>-tls
        hosts:
          - <app>.hl.mathielo.com
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

## Adding a New Service

The wildcard DNS record covers all `*.hl.mathielo.com` subdomains — no DNS changes needed. Just add an Ingress resource with the appropriate hostname and cert-manager annotation. See existing apps in `k3s/apps/` for examples.
