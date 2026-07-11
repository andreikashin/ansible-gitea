# Homelab Ansible

Ansible playbooks that provision and configure services running as Proxmox LXC
containers (Gitea, Jenkins, Harbor, NPM, Traefik, Portainer) plus Proxmox VM/CT
backups.

## Control node runs in WSL

Ansible does not run on Windows natively — run everything from **WSL** (a Linux
distro on the Windows host), not from PowerShell/CMD.

- The repo lives at `C:\Repos\ansible` on Windows, which is `/mnt/c/Repos/ansible`
  inside WSL. `cd` there in WSL before running any playbook.
- The SSH key used for all hosts is `~/.ssh/id_rsa` **in the WSL home**
  (see `ansible.cfg` / `inventory.ini`). Make sure it exists and its public key
  is authorized on the target hosts.
- `ansible.cfg` sets `host_key_checking = False` and `inventory = inventory.ini`.
  **Gotcha:** because `/mnt/c` is world-writable, Ansible silently ignores
  `ansible.cfg` there (you'll see `No inventory was parsed`). Force it with
  `export ANSIBLE_CONFIG=$PWD/ansible.cfg` (or pass `-i inventory.ini` on every
  run).
- Some paths are WSL-absolute (e.g. `connect_ip_rotation_release_credentials_to_jenkins.yml`
  reads the keystore from `/mnt/c/Repos/ip-rotation/ip-rotation-app`). Adjust
  `ip_rotation_app_repo_dir` if your checkout lives elsewhere.

```bash
# from WSL
cd /mnt/c/Repos/ansible
export ANSIBLE_CONFIG=$PWD/ansible.cfg   # /mnt/c is world-writable, so cfg auto-load is skipped
ansible-playbook deploy_jenkins.yml
```

## Playbook types

| Prefix        | Runs against            | Purpose |
|---------------|-------------------------|---------|
| `create_*`    | a PVE node (`pve1`)     | Provision the LXC CT (`pct create`), bootstrap SSH + base packages. |
| `deploy_*`    | the service's CT        | Install/run the service (Docker Compose) inside the CT. |
| `connect_*`   | a PVE node (`pve1`)     | Wire integrations into Jenkins. Reaches the CTs **through the PVE node as a jump host** (`pct exec` / `pct push`). |

### Why `connect_*` targets the PVE node

The `connect_*_to_jenkins.yml` playbooks target the PVE host and reach the
Jenkins/Gitea containers via `pct exec <ctid> -- ...` (and `pct push` to copy
files in, since the `template` module can't run through `pct` — the file is
rendered on the PVE node first, then pushed). This keeps the PVE node as the
single entry point into the containers.

## Provisioning a service (example: Jenkins)

```bash
cd /mnt/c/Repos/ansible

# 1. Provide the SSH public key that will be authorized in the new CT.
export JENKINS_BOOTSTRAP_SSH_PUBKEY="$(cat ~/.ssh/id_rsa.pub)"

# 2. Create the LXC CT on the PVE node.
ansible-playbook create_jenkins.yml

# 3. Deploy Jenkins into the CT.
ansible-playbook deploy_jenkins.yml

# 4. Wire integrations.
ansible-playbook connect_gitea_repo_to_jenkins.yml \
  -e gitea_repo_owner=<owner> -e gitea_repo_name=<repo>
ansible-playbook connect_harbor_robot_to_jenkins.yml
ansible-playbook connect_ip_rotation_release_credentials_to_jenkins.yml
```

Gitea uses `GITEA_BOOTSTRAP_SSH_PUBKEY` the same way for `create_gitea.yml`.

## `secrets.yml`

`connect_*` playbooks load `secrets.yml` (plaintext at the repo root — keep it
out of any public remote). Expected keys:

- `admin_login` / `admin_password` — Gitea **site admin**, used to revoke the
  previous Gitea service token before generating a new one (so tokens don't
  accumulate — a single fixed-name token is kept).
- `jenkins_harbor_service_token` — Harbor robot account token.
- `ip_rotation_release_store_password` / `ip_rotation_release_key_alias` —
  Android signing keystore secrets.

## Backups

`backup_proxmox_vms.yml` backs up Proxmox guests (both QEMU VMs and LXC CTs) via
`vzdump`, copies the archives to the control node, and removes the remote copy
on success. Target a subset with `-e proxmox_backup_vm_ids=[100,101]`.
