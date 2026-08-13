# Docs

- [Hardware](hardware.md) — Full inventory of all physical devices (compute, storage, networking)
- [Network & VLANs](network.md) — VLAN segmentation, WiFi SSIDs, DNS config, firewall rules
- [WiFi & Mesh Backhaul](wifi-mesh.md) — RF layout, mesh/MLO topology, how to measure a mesh link (and the traps that fake a dead one)
- [Tailscale](tailscale.md) — Private overlay network for remote access (IP convention, subnet routing, DNS)
- [Ingress & DNS](ingress-dns.md) — How services are accessed (split-DNS, TLS, Cloudflare role)
- [Monitoring & Dashboards](monitoring.md) — Prometheus scrape jobs, label gotchas, the custom Grafana dashboards, and the rack touchscreen kiosk
- [Media Stack](media-stack.md) — ARR + Usenet services setup and configuration
- [Tools](tools.md) — Catch-all namespace for misc self-hosted apps (SearXNG, Miniflux)
- [Longhorn Storage](storage-longhorn.md) — Distributed block storage: disk prep, install, PVC migration runbook, operational notes
- [PVC Maintenance](pvc-maintenance.md) — Runbook for PVC operations (scaling apps down/up, stopping pods, restoring from Longhorn backup or host tarball)
- [DAS Drive Swap](das-drive-swap.md) — Runbook for replacing the disks behind `/mnt/r0` on k3s-node-02 (quiesce, teardown, RAID 0 rebuild)
