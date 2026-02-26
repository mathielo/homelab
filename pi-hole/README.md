# Pi-hole (AdBlocker)

Using a Raspberry Pi 5 as the host for [Pi-hole](https://docs.pi-hole.net/) as the network’s default DNS Resolver. All network traffic is meant to go through it to block unwanted ads, malware or any other type of blacklisted domains.

# Setup

Install the official **Raspberry Pi OS** with the official [Raspberry Pi Imager](https://www.raspberrypi.com/software/). Then follow the instructions for a normal installation from [Pi-hole docs](https://docs.pi-hole.net/main/basic-install/).

## SSH Access

Enable SSH access and use `ssh-copy-id` to set up the trusted keys for access. Then disable SSH access with password:

```bash
sudo vi /etc/ssh/sshd_config

# Change the following values
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no # or "prohibit-password" to allow for root login with key

# Test the syntax after the changes
sudo sshd -t # should return nothing (or errors)

# Reload the service
sudo systemctl reload sshd
```

# Static IP addresses

Since the Pi-hole will be used as DNS resolver for the network, it needs to have static IP (v4 and v6) addresses.

```bash
# Fetch the NAME of the of the network connection
nmcli connection show # NAME: netplan-eth0

# Set static IPv4
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

# Backups

TODO

# NFS (Network File System)

TODO: Setup and document NFS

# Wireguard (?)

TODO: Check if need to configure wireguard again or can use UniFi’s Teleport instead
