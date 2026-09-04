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

## k3s cluster

`create_k3s.yml` clones the Ubuntu cloud template into one guest per inventory
host; `deploy_k3s.yml` installs k3s into them and joins them into a cluster.

```bash
cp host_vars/_k3s_node.yml.template host_vars/k3s_server1.yml   # one per node, gitignored
# list the hosts in [k3s_server_group] and [k3s_agent_group] in inventory.ini

ansible-playbook -i inventory.ini create_k3s.yml -e k3s_pve_target=pveX
ansible-playbook -i inventory.ini deploy_k3s.yml
```

The shape of the cluster is not baked into the playbooks: they build exactly the
hosts listed in the inventory. Put one host in `[k3s_server_group]` and you get a
single server on the embedded SQLite backend. Put three and the first one is
started with `--cluster-init`, which switches k3s to embedded etcd, and the rest
join it. Servers run `serial: 1` because a parallel start races etcd leader
election.

There is no pre-shared cluster token to manage. The first server generates one at
`/var/lib/rancher/k3s/server/node-token` on startup, and every later node reads it
from there, which is also why the servers have to be installed before the agents.

The template may carry a public key the control node has no pair for, so the
playbook writes its own key onto the clone instead of trusting what is baked in.
Templates are not shared between Proxmox nodes, and a freshly reinstalled node
has none at all, so a missing one is built from the official Ubuntu cloud image
the same way `deploy_vault.yml` builds a Debian one.

Version is pinned in `group_vars/k3s_cluster.yml`. Re-running the playbook does
**not** upgrade an existing installation: a cluster upgrade has its own order
(servers first, then agents) and should not happen as a side effect.

The last play verifies the result from the API rather than from systemd: it waits
until every node reports `Ready` and asserts that the set of node names matches
the inventory. It then writes a kubeconfig to the control node with the server
address rewritten, since k3s puts `127.0.0.1` in the file.

## Object storage

`create_minio.yml` clones the Ubuntu cloud template into a guest and attaches the
data disks; `deploy_minio.yml` installs MinIO into it and creates the buckets.

```bash
cp host_vars/_minio_node.yml.template host_vars/minio_node.yml   # fill in, gitignored
# add the host to [minio_group] in inventory.ini

ansible-playbook -i inventory.ini create_minio.yml -e minio_pve_target=pveX
ansible-playbook -i inventory.ini deploy_minio.yml
```

Data lives on one disk per device, not on a single large one. MinIO spreads
erasure coding across drives, and with a single drive there is no erasure coding
at all, only a copy. Four drives give EC:2. The disks are mounted by their
`by-id` path rather than `/dev/sdb`: kernel naming depends on discovery order and
changes between boots, and MinIO refuses to start when the drives come back in a
different order.

The server is **built from source** rather than installed from a package, and the
reason is worth knowing. The last MinIO release with published artifacts (deb,
rpm, container image) is 2025-09-07. The next one, 2025-10-15, fixes a privilege
escalation CVE in service accounts and STS session policies, but no binaries were
published for it: the release notes suggest `go install` or building the image
yourself. There have been no releases since. Installing the package would mean
knowingly putting a known hole into the store that will hold artifacts and
backups, so the role pins the fixed tag and compiles it. The build takes a few
minutes.

A binary produced by `go install` does not know its own version, because MinIO
stamps that via ldflags at release build time, so the role records the installed
version in a marker file next to the binary. Without it, bumping `minio_version`
would silently not rebuild.

There is no web console. The embedded UI was moved out of the community build in
2025, along with LDAP and OIDC login, so everything is managed through `mc`.

The last play checks what the store is for rather than whether the process is up:
that every drive is online and the backend really is in erasure mode, and that an
object can be written, read back byte for byte, and deleted.

## Backups

`backup_proxmox_vms.yml` backs up Proxmox guests (both QEMU VMs and LXC CTs) via
`vzdump`, copies the archives to the control node, and removes the remote copy
on success. Target a subset with `-e proxmox_backup_vm_ids=[100,101]`.

## Source of truth and network monitoring

Two services that belong together: NetBox records what the network *should* be,
Observium measures what it *is*.

### NetBox

`create_netbox.yml` builds the guest from a Debian cloud image;
`deploy_netbox.yml` creates the database on the data tier and brings up the
stack.

```bash
cp host_vars/_netbox_node.yml.template host_vars/netbox_node.yml   # fill in, gitignored
# add the host to [netbox_group] in inventory.ini

ansible-playbook -i inventory.ini create_netbox.yml
ansible-playbook -i inventory.ini deploy_netbox.yml
```

PostgreSQL is **external**, on the data tier: that is where the state lives and
where backups already run. The playbook creates the role and the database
itself, and re-applies the password on every run so the inventory stays the
single source of truth.

Redis is **local** to the guest, and there are two of them. The task queue has
to survive a restart; the cache is better off lost. Sharing one instance means
either losing jobs to memory eviction or keeping cache entries forever.

Moving NetBox to another node is one line in `host_vars` plus a rerun of both
playbooks. No data moves, because none of it is in the guest.

### Observium

`create_observium.yml` builds the guest, `deploy_observium.yml` installs
Observium Community Edition natively.

```bash
cp host_vars/_observium_node.yml.template host_vars/observium_node.yml
# add the host to [observium_group] in inventory.ini

ansible-playbook -i inventory.ini create_observium.yml
ansible-playbook -i inventory.ini deploy_observium.yml
```

Three deliberate departures from how everything else in this repo is built:

- **Debian 12, not 13.** Community Edition ships twice a year and trails Debian
  on PHP support. Trixie brings PHP 8.4 and CE breaks on it; bookworm gives 8.2.
- **Native install, not Docker.** Observium publishes no official image, and a
  third-party one would put the monitoring system at the mercy of someone else's
  release schedule.
- **MariaDB local to the guest.** The time series live in RRD files on disk; the
  database holds derived state that is rebuilt by re-polling. No reason to add a
  third engine to the tier that matters.

Scope is **network gear only**: the switch, the router, and anything else that
speaks SNMP and is not a host. Hosts stay with Prometheus and `lab-metrics`.
Two systems alerting independently about the same thing produce double the noise
in the same Telegram chat and an argument about which one is right.

`observium_devices` is empty until SNMP is enabled on the devices. Adding a
device that does not answer just records it as down.
