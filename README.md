# Homelab :house: :desktop_computer: :nerd_face: :lab_coat:

Docs, config, scripts and _whatnots_ for everything being set up and experimented with at my home lab.

# Prerequisites

Some tools need to be installed locally to be able to manage the homelab setup, namely:
- Ansible
- sshpass
- Docker + compose plugin
- k9s


```bash
# Ansible + sshpass
sudo add-apt-repository --yes ppa:ansible/ansible
sudo apt update
sudo apt install -y ansible software-properties-common sshpass

# Docker + compose plugin
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER  # log out and back in after this

# k9s
curl -sS https://webinstall.dev/k9s | bash
```
