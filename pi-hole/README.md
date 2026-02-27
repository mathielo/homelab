# Pi-hole (AdBlocker)

Using a Raspberry Pi 5 as the host for [Pi-hole](https://docs.pi-hole.net/) as the network's default DNS Resolver. All network traffic is meant to go through it to block unwanted ads, malware or any other type of blacklisted domains.

| Host   | Hardware       | IP           |
| ------ | -------------- | ------------ |
| pihole | Raspberry Pi 5 | 192.168.10.9 |

## Prerequisites

These steps are one-time manual steps that must be completed before running the Ansible playbooks.

### 1. Install Raspberry Pi OS

Use the official [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to flash **Raspberry Pi OS Lite (64-bit)** to the SD card. In the imager's advanced settings:

- Set hostname: `pihole`
- Set username: `me`
- Enable SSH with password authentication (will be disabled by the bootstrap playbook)

### 2. Set a static IP

Pi-hole must have a static IP since it's the network's DNS resolver. SSH into the Pi (using the DHCP-assigned IP or `pihole.local`) and run:

```bash
# List connections to find the NAME of the active connection
nmcli connection show

# Set static IPv4 (replace netplan-eth0 with your connection name)
sudo nmcli connection modify "netplan-eth0" \
  ipv4.method manual \
  ipv4.addresses 192.168.10.9/27 \
  ipv4.gateway 192.168.10.1 \
  ipv4.dns "9.9.9.9,149.112.112.112"

# Ensure IPv6 stays on auto (SLAAC)
# If the ISP changes the IPv6 prefix, this will automatically update
sudo nmcli connection modify "netplan-eth0" \
  ipv6.method auto

# Apply changes (will briefly drop SSH connection)
sudo nmcli connection up "netplan-eth0"
```

> :bulb: After this, the Pi is reachable at `192.168.10.9` — which is what the Ansible inventory uses.

## Bootstrap

The bootstrap playbook configures the host for remote management:
- Passwordless sudo for the `me` user
- SSH public key authentication (only the key in the playbook is authorized)
- Password-based SSH disabled

First run (password auth still enabled):

```bash
cd pi-hole/ansible
ansible-playbook 00-bootstrap.yaml --ask-pass --ask-become-pass
```

> :bulb: After bootstrap, password prompts are no longer needed.

> :warning: Once password SSH is disabled, losing your private key means you'll need physical access to recover. Keep a backup of your key.

## Install Pi-hole

Installs Pi-hole using the official installer in unattended mode:

```bash
ansible-playbook 01-pihole.yaml
```

This will:
- Write `/etc/pihole/setupVars.conf` with the network and DNS configuration
- Install Pi-hole (Quad9 as upstream DNS, query logging enabled)
- Set the admin password you enter at the prompt

The admin panel is available at `http://192.168.10.9/admin` after installation.

> :bulb: This playbook targets Pi-hole v6. The `pihole setpassword` command is v6-specific — for v5, the equivalent is `pihole -a -p <password>`.
