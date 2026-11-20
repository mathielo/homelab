# Devbox

`pi-devbox` (10.10.50.100) is a Raspberry Pi 5 running Raspberry Pi OS Lite (64-bit), powered by the official PoE HAT. It runs a [Herdr](https://herdr.dev) server as a system unit, with Claude Code and the Grok CLI in its panes and `kubectl`, `helm` and `k9s` bound to a read-only cluster identity.

| Host      | LAN IP       | Tailscale IP   |
| --------- | ------------ | -------------- |
| pi-devbox | 10.10.50.100 | 100.100.50.100 |

> Full hardware specs: [docs/hardware.md](../docs/hardware.md)

## Components

Versions are pinned in the play vars of `ansible/devbox.yaml` and tracked by Renovate, except where the source is an apt repository.

| Component   | Source                                                                                    |
| ----------- | ----------------------------------------------------------------------------------------- |
| Herdr       | `herdr-linux-aarch64` GitHub release asset, sha256-verified, at `/usr/local/bin/herdr`    |
| Claude Code | `claude-code` from Anthropic's apt repository, `stable` channel                           |
| Grok CLI    | `x.ai/cli/install.sh` at a pinned version, in `~/.grok/bin`                               |
| kubectl     | `pkgs.k8s.io` apt repository, minor version taken from `k3s_version`                      |
| Helm        | `get.helm.sh` release tarball, sha256-verified, at `/usr/local/bin/helm`                  |
| k9s         | GitHub release `.deb`, sha256-verified                                                    |
| homelab     | Read-only HTTPS clone of this repo's `main` at `~/src/homelab`, never updated by the play |

The Claude Code signing key must have fingerprint `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE` or the play stops before adding the repository. Neither agent CLI updates itself. Claude Code moves with `sudo apt upgrade` (unattended-upgrades takes only the Debian and Raspberry Pi origins), and the Grok CLI only with `grok_version`, since the play sets `auto_update = false` in `~/.grok/config.toml`.

## Herdr

`herdr.service` runs `herdr server` as `m8hl` from boot, so no login session has to stay open. Its socket lives in `~/.config/herdr/`, where any `herdr` client running as `m8hl` finds it.

- **Environment**: `/etc/herdr/herdr.env` (`m8hl`, `0600`) holds `ANTHROPIC_API_KEY` and `XAI_API_KEY`; the unit adds `~/.grok/bin` and `~/.local/bin` to `PATH`. Every pane inherits both.
- **Stop**: `KillMode=mixed` sends SIGTERM to the server alone, which saves the session layout and stops its panes within `TimeoutStopSec=30`.
- **Config**: `~/.config/herdr/config.toml` gets `onboarding = false` and `[update] version_check = false`; other keys are left as set.
- **Integrations**: `herdr integration install claude` and `grok` write their `SessionStart` hooks into `~/.claude/hooks/` and `~/.grok/hooks/`, so agent panes resume their sessions after a server restart. The play reinstalls them whenever the Herdr binary changes.

The playbook never restarts Herdr or reboots the host, since both end every running agent process. When the binary, config, env file or unit changes it prints a reminder to run `sudo systemctl restart herdr`; when the boot config changes it prints one to reboot.

## Cluster access

`k3s/apps/devbox/`, synced by the `devbox` Argo CD app, creates the `devbox-reader` ServiceAccount in the `devbox` namespace:

- bound to the built-in `view` ClusterRole, which excludes Secrets
- plus the `devbox-reader` ClusterRole: `get`/`list`/`watch` on nodes, persistentvolumes, namespaces, storageclasses and the `argoproj.io`, `longhorn.io`, `cert-manager.io` and `acme.cert-manager.io` groups
- with a long-lived `kubernetes.io/service-account-token` Secret, `devbox-reader-token`

`~/.kube/config` (`0600`) points at `https://10.10.50.10:6443` with that token and the cluster CA.

## Setup

1. **Cluster identity**: once Argo CD has synced the `devbox` app, read the token and the CA from the workstation:

   ```bash
   kubectl -n devbox get secret devbox-reader-token -o jsonpath='{.data.token}' | base64 -d
   kubectl -n devbox get secret devbox-reader-token -o jsonpath='{.data.ca\.crt}'
   ```

2. **Secrets**: create `ansible/devbox/devbox.sops.yaml` with these keys:

   | Key                 | Value                                                |
   | ------------------- | ---------------------------------------------------- |
   | `anthropic_api_key` | Anthropic Console API key                            |
   | `xai_api_key`       | xAI Console API key                                  |
   | `devbox_kube_token` | decoded `token` from step 1                          |
   | `devbox_kube_ca`    | `ca.crt` from step 1, left base64-encoded as printed |

3. **Playbooks**, from the repo root:

   ```bash
   ansible-playbook -i ansible/inventory.ini ansible/bootstrap.yaml --limit pi-devbox
   ansible-playbook -i ansible/inventory.ini ansible/tailscale.yaml --limit pi-devbox
   ansible-playbook -i ansible/inventory.ini ansible/devbox.yaml
   ```

   In the **Tailscale admin console**, set the machine's address to `100.100.50.100` (machine settings → **Addresses**).

4. **Reboot** once the playbook reports a boot config change: `ssh pi-devbox sudo reboot`.

5. **Claude Code API key**: the first interactive `claude` run asks once whether to use `ANTHROPIC_API_KEY`. Accept it; the answer is stored in `~/.claude.json`.

6. **Connect** from a Herdr client:

   ```bash
   herdr machine add pi-devbox
   ```

   `pi-devbox` is the alias in [`.config/ssh.config`](../.config/ssh.config).

## Host settings

| Setting                   | Where                                       | Why                                                                               |
| ------------------------- | ------------------------------------------- | --------------------------------------------------------------------------------- |
| WiFi disabled             | `dtoverlay=disable-wifi`                    | Wired over PoE, radio unused                                                      |
| Bluetooth disabled        | `dtoverlay=disable-bt`                      | Unused; `bluetooth.service` also disabled                                         |
| Persistent journal        | `/etc/systemd/journald.conf.d/storage.conf` | Overrides Raspberry Pi OS's `40-rpi-volatile-storage.conf`, which keeps it in RAM |
| netplan configs root-only | `/etc/netplan/*.yaml` mode `0600`           | netplan warns on every run while they are readable by others                      |
