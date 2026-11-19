# ansible/: cluster and media stack as code

Ansible for the 5-node Proxmox cluster `media` (repos, cluster join, Ceph), the media-stack VM host
and the media stack on it; Terraform in [`../terraform/`](../terraform/) defines VM 200 itself.
Together they replace the old `pve-tools/*.sh` and `stack/*.sh` scripts.
Operator runbook: [docs/media-stack.md](../docs/media-stack.md). Design and contract:
[docs/iac-batch-kickstart.md](../docs/iac-batch-kickstart.md).

**Run everything from `ansible/`** (that is where `ansible.cfg` is picked up); Terraform runs from
`terraform/`.

## 1. Prerequisites (on the Mac)

| Need | Check / install |
|---|---|
| ansible-core ≥ 2.22 on Python ≤ 3.14 | `ansible --version`. Python 3.15 breaks ansible-core's dataclasses patch: pin the venv/pipx interpreter to 3.14 |
| Collections (pinned) | `ansible-galaxy collection install -r requirements.yml` |
| ansible-lint (for changes) | `ansible-lint --version` |
| Terraform ≥ 1.17 | `terraform version` |
| 1Password CLI with desktop integration | `op whoami` (lookups and `op run` resolve secrets at runtime) |
| SSH key `~/.ssh/id_ed25519` | Its `.pub` must be in root's `authorized_keys` on the nodes: run `playbooks/ssh-keys.yml` once (below). The VM's `media` user gets the same key from cloud-init |

Smoke test: `ansible all -m ansible.builtin.ping` (6 hosts: 5 nodes + `media-stack`).

## 2. Inventory and shared vars

`inventory/hosts.yml`:

| Group | Hosts | Connection |
|---|---|---|
| `pve_nodes` | intel-1ecbc8 `192.168.8.234`, intel-a163f8 `.123`, intel-177e78 `.162`, intel-91c45d `.196`, intel-d1babf `.194` | `root`, key auth |
| `ceph_mons` | intel-1ecbc8, intel-a163f8, intel-177e78 (MON + MGR) | as `pve_nodes` |
| `ceph_osds` | OSD nodes, each with host var `ceph_osd_serials` (disk serials) | as `pve_nodes` |
| `media_vms` | `media-stack` `192.168.8.200` (VM 200) | user `media`, `become: true` |

Shared vars live in `inventory/group_vars/all.yml` (next to the inventory, so every playbook
loads them): `op_vault` (1Password vault Lab), LAN `192.168.8.0/24`
and gateway `.1`, `pve_api_node` (`192.168.8.234`), `ceph_pool` (`media-ec`), VM facts (VMID 200,
IP `.200`), stack paths (`/data`, `/opt/media-stack/{config,stack}`), PUID/PGID 1000, UMASK 002, TZ.

Ad-hoc commands replace `pvessh.sh`:

```sh
ansible intel-a163f8 -a 'qm status 200'                         # one node
ansible pve_nodes -a 'pveversion'                               # all nodes
ansible intel-a163f8 -m ansible.builtin.shell -a 'qm config 200 | grep ^scsi'   # pipes need shell
```

## 3. How to run

| Playbook | Hosts | Tags | What it changes | Old script |
|---|---|---|---|---|
| `playbooks/ssh-keys.yml` | `pve_nodes` (run_once) | | Adds `~/.ssh/id_ed25519.pub` to root's `/etc/pve/priv/authorized_keys` (cluster-wide file); password login stays as fallback | `pvessh.sh` / `askpass.sh` password login |
| `playbooks/pve-repos.yml` | `pve_nodes` | | No-subscription deb822 repos (PVE + Ceph tentacle), enterprise repos disabled, apt cache | `fix-repos.sh` |
| `playbooks/inventory-report.yml` | `pve_nodes` | | Nothing (read-only readiness report) | `inventory.sh` |
| `playbooks/pve-cluster.yml` | `pve_nodes` | | Joins a node to cluster `media` via the PVE API; skipped when the node is already clustered | `join.sh` |
| `playbooks/ceph.yml` | `pve_nodes` / `ceph_mons` / `ceph_osds` | `install`, `init`, `mons`, `pool`, `status` (all run by default); `osds` (tagged `never`) | Ceph packages, `ceph.conf`, MON/MGR, EC 2+1 pool + PVE storage `media-ec`; `status` is read-only. `osds` zaps and creates OSDs: **destructive**, needs `--tags osds -e confirm_destroy=<serial>` | `ceph-setup.sh` |
| `playbooks/pve-terraform-token.yml` | `pve_api_node` (192.168.8.234) | | API user/token `terraform@pve!media` with a scoped role; token secret stored in 1Password item `pve-terraform` | (new) |
| `terraform/` (not a playbook) | PVE API | | Debian 13 cloud image + VM 200 (`bpg/proxmox` 0.123.1), `prevent_destroy` | `vm-media-stack.sh image` / `create` / `start` |
| `playbooks/media-host.yml` | `media_vms` | | docker-ce + compose plugin, rsync, qemu-guest-agent, data disk (formatted **only if blank**), `/data` fstab mount, `/data` tree, `/opt/media-stack` | `vm-media-stack.sh bootstrap` |
| `playbooks/secrets-init.yml` | `localhost` | | Creates 1Password item `media-stack` / adds missing fields only; never overwrites | `stack/secrets-init.sh` |
| `playbooks/media-stack.yml` | `media_vms` | | Syncs `stack/` to `/opt/media-stack/stack`, renders `<svc>/secrets.env` (0600) from 1Password, `docker compose up` (never `down`) | `stack/deploy.sh` |
| `playbooks/arr-config.yml` | `localhost` → app APIs | | Root folders: Sonarr `/data/media/tv` + `/data/media/anime`, Radarr `/data/media/movies`, Lidarr `/data/media/music` (only adds missing); download client qBittorrent (`qbittorrent:8080`, user `admin`) with category Sonarr `tv`, Radarr `movies`, Lidarr `music` (adds, or fixes it when settings differ or its test fails) | `stack/{sonarr,radarr,lidarr}/configure.sh`, manual download-client setup |
| `playbooks/qbt-prowlarr-config.yml` | `localhost` → app APIs | | qBittorrent password, prefs/save path, categories `movies tv anime music`; Prowlarr apps (Sonarr, Radarr, Lidarr) + qBittorrent download client | `stack/{qbittorrent,prowlarr}/configure.sh` |

Usage pattern, every playbook:

```sh
cd ansible
ansible-playbook playbooks/<name>.yml --check --diff    # dry run first; review every diff
ansible-playbook playbooks/<name>.yml                   # apply
ansible-playbook playbooks/<name>.yml                   # rerun: must report changed=0
```

Limit to hosts with `-l <host>`, to phases with `--tags`. Each playbook's header comment documents
its variables.

Terraform (VM 200), see [terraform/README.md](../terraform/README.md):

```sh
cd terraform
terraform init
op run --env-file .env.op -- terraform plan     # must say "No changes" against the live VM
op run --env-file .env.op -- terraform apply
```

`.env.op` holds only `op://` references to the `pve-terraform` token; state is local
(`terraform.tfstate`, gitignored, no secrets): back it up after each apply. VM 200 has
`prevent_destroy`, so a plan that would replace it fails instead.

## 4. Bring-up order from scratch

| # | Step | Command (from `ansible/` unless noted) |
|---|---|---|
| 1 | Root SSH key on the nodes | `ansible-playbook playbooks/ssh-keys.yml` |
| 2 | Repos, then readiness report | `ansible-playbook playbooks/pve-repos.yml`, `ansible-playbook playbooks/inventory-report.yml` |
| 3 | Cluster join | `ansible-playbook playbooks/pve-cluster.yml` |
| 4 | Ceph install, config, MON/MGR | `ansible-playbook playbooks/ceph.yml --tags install,init,mons` |
| 5 | OSDs (destructive, per disk) | `ansible-playbook playbooks/ceph.yml --tags osds -l <node> -e confirm_destroy=<serial>` |
| 6 | EC pool + storage, check health | `ansible-playbook playbooks/ceph.yml --tags pool,status` |
| 7 | Terraform API token | `ansible-playbook playbooks/pve-terraform-token.yml` |
| 8 | VM 200 | `cd terraform && op run --env-file .env.op -- terraform apply` |
| 9 | VM host: docker, `/data` | `ansible-playbook playbooks/media-host.yml` |
| 10 | App secrets in 1Password | `ansible-playbook playbooks/secrets-init.yml` |
| 11 | Deploy the stack | `ansible-playbook playbooks/media-stack.yml` |
| 12 | qBittorrent + Prowlarr app sync | `ansible-playbook playbooks/qbt-prowlarr-config.yml` |
| 13 | *arr root folders + qBittorrent download client (needs the qBittorrent password from step 12) | `ansible-playbook playbooks/arr-config.yml` |

Then the manual steps in [docs/media-stack.md](../docs/media-stack.md) section 4 (Jellyfin wizard,
indexers). On the existing cluster steps 1-13 are converge runs: each must report `changed=0`,
and `terraform plan` must show no changes.

## 5. Converge expectation and safety rules

- The cluster and VM are live. A playbook run against them is expected to report **`changed=0`**;
  any change on a working setup is a bug in the role, not in the host. Always `--check --diff` first.
- `ceph.yml --tags osds` is the only path that touches OSD disks. It is tagged `never` and refuses
  without `-e confirm_destroy=<exact serial>`. Never run it against an existing OSD.
- `media-host.yml` formats the VM's data disk **only when `blkid` finds no filesystem**. It never
  reformats `/data`.
- `media-stack.yml` never runs `docker compose down`; a removed service must be taken down by hand.
- Nothing here touches node boot disks or corosync config; `pve-cluster.yml` skips nodes that are
  already clustered.
- Terraform: never apply a plan that replaces or destroys VM 200.

## 6. Secrets

All secrets stay in 1Password vault **Lab** (`xmjfgnsondcvlqa6bovelwdztm`) and are resolved at
runtime (`community.general.onepassword` lookups, `op run`); tasks that touch them use `no_log`, and
resolved values only land on the target (mode 0600). Nothing secret is committed.

| 1Password item | Holds | Used by |
|---|---|---|
| `media-stack` | `sonarr_api_key`, `radarr_api_key`, `lidarr_api_key`, `prowlarr_api_key`, `qbittorrent_password` | `secrets-init.yml` (creates), `media-stack.yml`, `arr-config.yml`, `qbt-prowlarr-config.yml` |
| `pve-terraform` | token secret of `terraform@pve!media` | `pve-terraform-token.yml` (creates), `terraform/.env.op` |
| one item per node (IDs were in `pve-tools/nodes.txt`) | root password | password fallback only (e.g. before `ssh-keys.yml` has run) |
