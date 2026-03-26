# Hardware

All physical devices in the homelab.

## Compute

| Host          | Hardware                  | CPU                          | RAM       | Storage        | VLAN | IP           |
| ------------- | ------------------------- | ---------------------------- | --------- | -------------- | ---- | ------------ |
| k3s-node-01   | Lenovo ThinkCentre M75q-1 | Ryzen 5 PRO 3400GE @ 3.30GHz | 32GB DDR4 | 256GB NVMe SSD | 50   | TBD          |
| k3s-node-02   | Lenovo ThinkCentre M715Q  | Ryzen 3 2200GE @ 3.20GHz     | 32GB DDR4 | 256GB NVMe SSD | 50   | 10.10.50.3   |
| pihole        | Raspberry Pi 5 Model B    | ARM Cortex-A76 (4-core)      | 8GB       | SD card        | 53   | 10.10.53.53  |
| homeassistant | Raspberry Pi 5 Model B    | ARM Cortex-A76 (4-core)      | 8GB       | SD card        | 50   | 10.10.50.123 |

## Storage

| Device | Hardware  | Storage                                                | VLAN | IP        |
| ------ | --------- | ------------------------------------------------------ | ---- | --------- |
| UNAS-4 | UniFi NAS | 4x4TB HDD (RAID 5, ~12TB usable) + 500GB M.2 SSD cache | 1    | 10.10.1.4 |

## Networking

All UniFi networking equipment lives on VLAN 1 (management). Only the gateway, NVR, and NAS have static IPs; everything else uses DHCP.

| Device          | Model              | IP        |
| --------------- | ------------------ | --------- |
| R18 UGC Max     | UniFi Gateway      | 10.10.1.1 |
| UNVR-I          | UniFi NVR Instant  | 10.10.1.2 |
| USW Lite 8 PoE  | UniFi Switch       | Dynamic   |
| U7 Pro XG       | UniFi AP           | Dynamic   |
| UDB Homelab     | UniFi Dream Bridge | Dynamic   |
| UDB Living Room | UniFi Dream Bridge | Dynamic   |
