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
| `configure_*` | network hardware        | Configure the switch and the router (see below). Not SSH-to-Linux: `network_cli` for IOS, the RouterOS API for MikroTik. |

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

## Network hardware

`configure_network.yml` configures the Cisco 2960X (L2 only: VLANs, trunks,
access ports, optional LACP) and the MikroTik router (all of L3: gateways,
DHCP, NAT, inter-VLAN firewall). Both read the same segment map from
`group_vars/network_group.yml`, so the topology is edited in one place.

Extra requirements on the control node:

```bash
sudo apt install python3-paramiko python3-librouteros
```

Setup:

1. `cp group_vars/network_group.yml.template group_vars/network_group.yml` and
   fill in the real subnets (the committed template uses 198.18.0.0/15
   placeholders; the real file is gitignored).
2. `cp host_vars/_net_switch.yml.template host_vars/net_switch.yml` and the same
   for `_net_router.yml.template`.
3. Fill `switch_admin_login` / `switch_admin_password` /
   `switch_enable_password` / `router_admin_login` / `router_admin_password`
   in `secrets.yml`.

```bash
ansible-playbook configure_network.yml --check --diff   # always first
ansible-playbook configure_network.yml --tags switch
ansible-playbook configure_network.yml --tags router
```

Both roles reconfigure the path they are running over. They snapshot the
current config into `net_backup_dir` (`~/net-backups` by default) before
touching anything, but keep a console cable for the switch and MAC-winbox for
the router within reach. The router role owns the `filter` and `nat` tables
completely: rules absent from the templates are deleted.

## Mail server

`create_mail.yml` clones the Debian template into a dedicated guest;
`deploy_mail.yml` installs [Stalwart](https://github.com/stalwartlabs/stalwart)
into it and configures the server.

```bash
cp host_vars/_mail_node.yml.template host_vars/mail_node.yml   # fill in, gitignored
# add the host to [mail_group] in inventory.ini

ansible-playbook -i inventory.ini create_mail.yml
ansible-playbook -i inventory.ini deploy_mail.yml
```

Stalwart 0.16 has almost no file configuration. `config.json` holds only the
choice of storage backend; domains, DKIM keys, accounts and listeners live in a
registry inside that store and are edited over JMAP. So the role installs the
binary and the unit as files, then talks to the running server through the API.

Until `config.json` exists the server comes up in **bootstrap mode** on port
8080 with a single writable object, `x:Bootstrap`. One `set` on it creates the
store, the domain, the DKIM keys and the admin account, after which the server
switches to normal mode. `STALWART_RECOVERY_ADMIN` in `stalwart.env` is what
makes this scriptable: it pins an admin credential that works before any
directory exists, so the playbook never has to scrape a generated password out
of the logs.

The binary is installed natively rather than in a container, unlike the rest of
the lab. The mail server is the only service exposed to the internet, so it does
without an extra root daemon underneath it; and ports 25/465/587/993 plus the
real remote IP of the sender come for free, which matters because the remote IP
is half of every antispam and DNSBL decision.

What the playbook deliberately does **not** do: touch DNS, request a
certificate, or configure a smarthost for outbound mail. Those are gated on
things outside Ansible: the MX cutover, a reachable port 443 or a DNS provider
token, and a relay contract. Inbound mail does not depend on any of them.

After a run the records the server expects in the zone (DKIM public keys
included) are written to `/etc/stalwart/dns-records.txt` on the guest and echoed
at the end of the play.

## Backups

`backup_proxmox_vms.yml` backs up Proxmox guests (both QEMU VMs and LXC CTs) via
`vzdump`, copies the archives to the control node, and removes the remote copy
on success. Target a subset with `-e proxmox_backup_vm_ids=[100,101]`.
