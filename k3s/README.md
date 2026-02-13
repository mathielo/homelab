# k3s Cluster

## Prerequisites

1. Install **Ubuntu Server** on the target machine
   - During install, create user: `k3s`
   - Enable OpenSSH server when prompted
2. Install Ansible and sshpass on your local machine:
   ```bash
   sudo add-apt-repository --yes --update ppa:ansible/ansible
   sudo apt install ansible sshpass
   ```

## Bootstrap

The bootstrap playbook configures the server for remote management:
- Passwordless sudo for the `k3s` user
- SSH public key authentication (only the key in the playbook is authorized)
- Password-based SSH disabled

First run (password auth still enabled):

```bash
cd k3s/ansible
ansible-playbook bootstrap.yml --ask-pass --ask-become-pass
```

After bootstrap, password prompts are no longer needed:

```bash
ansible-playbook some-playbook.yml
```

> **Note:** Once password SSH is disabled, losing your private key means you'll need physical/console access to recover. Keep a backup of your key.
