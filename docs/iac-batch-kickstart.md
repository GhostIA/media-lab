# Kickstart: replace the shell scripts with Ansible + Terraform via `/batch`

How to launch the parallel `/batch` job that rewrites every shell script in this repo as Ansible
(cluster, Ceph, VM host, media stack) plus Terraform (VM 200), and what the coordinator and its
workers need to know first.

## 1. Before you run it

- [ ] The *arr batch has landed: PRs #4 (VM script), #5 (deploy.sh tar fix), #6 Radarr, #7 Sonarr,
      #8 Jellyfin and the Prowlarr + qBittorrent PR are merged, and `main` is pulled. The scripts
      on `main` are the **reference behaviour** this batch must reproduce.
- [ ] Tools on the Mac: `ansible --version` (core ≥ 2.22, collections `community.general`,
      `community.docker`, `ansible.posix`), `ansible-lint`, `terraform version` (≥ 1.17).
- [ ] `gh auth status` (GhostIA), `op whoami` (1Password desktop integration on).
- [ ] Cluster healthy: `pve-tools/ceph-setup.sh status` → `HEALTH_OK`, 4 OSDs up; all six
      health endpoints on 192.168.8.200 answer (see `docs/media-stack.md`).
- [ ] Decisions in §4 are confirmed (or edited).
- [ ] **Step 0 is merged** (§6): the coordinator lands the Ansible skeleton before spawning workers.

## 2. The command

```
/batch Replace every shell script in this repo with Ansible (plus Terraform for VM 200) as described in docs/iac-batch-kickstart.md. Read CLAUDE.md, docs/iac-batch-kickstart.md, docs/media-stack.md and the scripts being replaced first; follow the kickstart's contract, work units and e2e recipe. The cluster and VM are LIVE: every playbook must converge to changed=0 against them and terraform plan must show no changes after import. Never touch Ceph OSD disks, node boot disks, corosync config or the VM's data disk. Never commit secrets (1Password lookups / op:// only).
```

## 3. What exists today (reference behaviour)

| Script | Does | Replaced by unit |
|---|---|---|
| `pve-tools/pvessh.sh`, `askpass.sh`, `nodes.txt` | SSH to nodes with root passwords from 1Password | Step 0 (inventory + keys); files deleted in §8 cleanup |
| `pve-tools/inventory.sh` | read-only readiness report | 1 |
| `pve-tools/fix-repos.sh` | enterprise → no-subscription deb822 repos (PVE + Ceph tentacle) | 1 |
| `pve-tools/join.sh` | join a node through the PVE API, guarded | 2 |
| `pve-tools/ceph-setup.sh` | install / init / mons / osds (DESTRUCTIVE) / EC 2+1 pool + `media-ec` storage / status | 2 |
| `pve-tools/nfs-setup.sh` | old NFS storage (obsolete since Ceph) | 2 (deleted, not ported) |
| `pve-tools/vm-media-stack.sh` | image / create / start (VM 200) | 3 (Terraform) |
| `pve-tools/vm-media-stack.sh bootstrap` | docker, data disk, `/data` tree | 4 |
| `stack/deploy.sh`, `stack/secrets-init.sh` | ship stack, inject secrets, compose up; create 1Password item | 5 |
| `stack/{sonarr,radarr,lidarr}/configure.sh` | *arr root folders | 6 |
| `stack/{qbittorrent,prowlarr}/configure.sh` | qBittorrent prefs/categories, Prowlarr app sync | 7 |

Live state to converge on: 5 nodes (`192.168.8.{234,123,162,196,194}`), PVE 9.2, Ceph 20 tentacle,
MON/MGR on 1ecbc8/a163f8/177e78, OSD serials as in `ceph-setup.sh`, pool `media-ec` (EC 2+1, host
failure domain); VM 200 `media-stack` on intel-a163f8 per `docs/media-stack.md`; containers
jellyfin, sonarr, radarr, lidarr, prowlarr, qbittorrent running in compose project `media-stack`.

## 4. Decisions (confirm before running)

| # | Decision | Default in this doc |
|---|---|---|
| D1 | VM 200 definition | **Terraform**, `bpg/proxmox` provider (confirmed) |
| D2 | Ansible → node auth | **SSH key** (`~/.ssh/id_ed25519.pub`) added to root's `authorized_keys` by Step 0 using `pvessh.sh` one last time. On PVE this file is `/etc/pve/priv/authorized_keys`, shared cluster-wide. Password login stays enabled as a fallback. |
| D3 | NFS scripts | **Delete** (`nfs-setup.sh`, the `teardown-nfs` phase); git history keeps them |
| D4 | Terraform state | **Local** `terraform/terraform.tfstate`, gitignored; back it up after each apply (holds no secrets: API token comes from env) |
| D5 | Terraform → PVE auth | API token `terraform@pve!media` (role scoped to VM 200's needs + `media-ec`/`local` datastore), secret stored in 1Password item `pve-terraform` (vault Lab), passed with `op run` |

## 5. Contract (all workers follow this)

- **Layout:** `ansible/` (`ansible.cfg`, `inventory/hosts.yml`, `inventory/group_vars/`, `inventory/host_vars/`,
  `requirements.yml`, `roles/<role>/`, `playbooks/<name>.yml`) and `terraform/`. Each unit owns
  only its roles, playbooks and the files listed in §7. Shared files belong to Step 0 and are read-only for workers.
- **Inventory groups (Step 0):** `pve_nodes` (all 5, `ansible_host` = IP, `ansible_user=root`),
  `ceph_mons` (1ecbc8, a163f8, 177e78), `ceph_osds` (with host var `ceph_osd_serials`),
  `media_vms` (`media-stack`, `192.168.8.200`, `ansible_user=media`, `become: true`).
- **Shared vars (`inventory/group_vars/all.yml`, Step 0):** `op_vault: xmjfgnsondcvlqa6bovelwdztm`, LAN
  `192.168.8.0/24`, gateway `.1`, `pve_api_node: 192.168.8.234`, `ceph_pool: media-ec`, VM facts
  (VMID 200, IP .200), stack paths (`/data`, `/opt/media-stack/{config,stack}`, PUID/PGID 1000, UMASK 002, TZ).
- **Secrets:** read with `lookup('community.general.onepassword', ...)` or `op read`; every task that
  touches a secret has `no_log: true`; resolved secrets only ever land on the target (mode 0600).
- **Destructive steps:** OSD creation/zap and any disk format are tagged `never` *and* require
  `-e confirm_destroy=<exact serial or device>`; the data-disk format only runs when `blkid` finds nothing.
- **Style:** FQCN modules, `ansible-lint` production profile clean, prefer modules over
  `command`/`shell`; where only a CLI exists (`pveceph`, `pvecm`, `qm`) use `command` with
  `creates:`/`changed_when:` guards so reruns report `changed=0`. Each playbook has a header comment with usage.
- **Attribution & secrets:** per `CLAUDE.md`, commits and PRs credit GhostIA only, with no Claude trailers or footers.

## 6. Step 0 (coordinator, before spawning workers; one PR, merged first)

`ansible/ansible.cfg`, `ansible/inventory/hosts.yml`, `ansible/inventory/group_vars/all.yml`,
`ansible/requirements.yml` (pinned collections), `ansible/playbooks/ssh-keys.yml` (D2), `.gitignore`
entries for Terraform state/`.terraform/`. Verify: `ansible all -m ping` reaches all 6 hosts by key.

## 7. Work units (independent; one PR each)

| # | Unit | Files | Change |
|---|---|---|---|
| 1 | Node baseline + report | `roles/pve_repos/`, `playbooks/pve-repos.yml`, `playbooks/inventory-report.yml`; delete `inventory.sh`, `fix-repos.sh` | deb822 repo files via `ansible.builtin.deb822_repository`, enterprise disabled, apt cache update; read-only report playbook with the same fields as `inventory.sh` |
| 2 | Cluster + Ceph | `roles/pve_cluster/`, `roles/ceph/`, `playbooks/pve-cluster.yml`, `playbooks/ceph.yml`; delete `join.sh`, `ceph-setup.sh`, `nfs-setup.sh` | join via `uri` to the PVE API (skipped when `corosync.conf` exists); Ceph tags `install,init,mons,pool,status`; `osds` behind `never` + `confirm_destroy` |
| 3 | Terraform VM 200 | `terraform/` (`versions.tf` pinned to `bpg/proxmox` 0.123.1, `main.tf`, `variables.tf`, `outputs.tf`, `README.md`, `.env.op`, `import.sh` or `import {}` blocks), `playbooks/pve-terraform-token.yml`; delete `vm-media-stack.sh` | cloud image download + VM 200 matching the live config exactly, `prevent_destroy`; API token (D5) created by `pve-terraform-token.yml` on `pve_api_node`; import, then `plan` = no changes |
| 4 | VM host role | `roles/media_host/`, `playbooks/media-host.yml` | docker-ce repo + packages (add `rsync`), qemu-guest-agent, data disk format-if-blank, fstab by UUID with `nofail`, docker requires `/data` mount, `/data` tree + `/opt/media-stack` perms |
| 5 | Stack deploy + secrets | `roles/media_stack/`, `playbooks/media-stack.yml`, `playbooks/secrets-init.yml`; delete `stack/deploy.sh`, `stack/secrets-init.sh` | sync `stack/`, render `<svc>/secrets.env` from 1Password (`no_log`, 0600), `community.docker.docker_compose_v2` with every `stack/*/compose.yaml`; idempotent 1Password item creation (only missing fields) |
| 6 | *arr configuration | its role, `playbooks/arr-config.yml`; delete `stack/{sonarr,radarr,lidarr}/configure.sh` | `uri` tasks from localhost: Sonarr tv+anime, Radarr movies, Lidarr music root folders. Only creates what's missing |
| 7 | qBittorrent + Prowlarr configuration | its role, `playbooks/qbt-prowlarr-config.yml`; delete `stack/{qbittorrent,prowlarr}/configure.sh` | `uri` tasks from localhost: qBittorrent password/save path/categories; Prowlarr app sync + download client. Only creates what's missing |
| 8 | Docs | `docs/media-stack.md`, `ansible/README.md`, this file | replace every script command with the playbook / terraform equivalent, add a "how to run" table (playbook, hosts, tags, what it changes, old script) |

Units 1–8 only need Step 0 to exist. None depends on another unit's PR.

## 8. After the batch (coordinator)

Once all PRs are merged and the full converge run is clean: delete `pve-tools/pvessh.sh`,
`askpass.sh` and `nodes.txt` (and `pve-tools/` if empty). Update `CLAUDE.md` "Node access" to
`ansible <host> -m ...`. Run `ansible-playbook playbooks/site.yml --check --diff` then for real, and
`terraform plan`; all must show no changes.

## 9. End-to-end check (each worker, for its unit)

1. Static: `ansible-lint` on your roles/playbooks; `ansible-playbook --syntax-check`;
   Terraform: `terraform fmt -check && terraform validate`.
2. Dry run against the live hosts: `ansible-playbook playbooks/<yours>.yml --check --diff`. Review
   every diff. Anything that would modify a working setup is a bug in your role, not in the host.
3. Real run, then a second real run: the second must report **`changed=0`** (the first may only
   change things that are cosmetic and explained in the PR, e.g. file ownership on a managed file).
4. Behaviour equals the old script: unit 1 report matches `inventory.sh` output; unit 2
   `status` matches `ceph-setup.sh status`; unit 4 `/data` + docker unchanged; unit 5 all six
   containers still `healthy` and `curl` matrix from `docs/media-stack.md` passes; units 6–7 the APIs
   show the same root folders / categories / apps as before.
5. Terraform (unit 3): after import `terraform plan` shows **No changes**, or only in-place updates
   that are explained in the PR. Never apply a plan that replaces or destroys VM 200.
6. Afterwards Ceph `HEALTH_OK` (`ansible-playbook playbooks/ceph.yml --tags status`, or the old script).
