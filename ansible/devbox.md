# Devbox

`pi-devbox` (10.10.50.100) is a Raspberry Pi 5 running Raspberry Pi OS Lite (64-bit), powered by the official PoE HAT.

# Setup

Run `bootstrap.yaml` first, then:

```sh
ansible-playbook -i ansible/inventory.ini ansible/devbox.yaml
```

The playbook never reboots the host. When the boot config changes it prints a reminder; reboot manually when no agents are running.

| Setting            | Where                    | Why                                       |
| ------------------ | ------------------------ | ----------------------------------------- |
| WiFi disabled      | `dtoverlay=disable-wifi` | Wired over PoE, radio unused              |
| Bluetooth disabled | `dtoverlay=disable-bt`   | Unused; `bluetooth.service` also disabled |
