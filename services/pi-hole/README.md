# Raspberry Pi: Pi-hole (AdBlocker)

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

# Backups

TODO

# NFS (Network File System)

TODO: Setup and document NFS

# Wireguard (?)

TODO: Check if need to configure wireguard again or can use UniFi’s Teleport instead
