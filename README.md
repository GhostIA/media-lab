# media-lab

A home media server, as code. Five small Intel boxes run a **Proxmox VE** cluster called `media`,
their spare disks are pooled with **Ceph** (erasure-coded 2+1, so any one box can die without
losing data), and one VM on top runs the media apps in Docker:

| App | What it's for | URL |
|---|---|---|
| **Jellyfin** | Watch and listen: movies, TV, anime, music | <http://192.168.8.201:8096> |
| **Sonarr** | Finds and organises TV shows and anime | <http://192.168.8.200:8989> |
| **Radarr** | Same for movies | <http://192.168.8.200:7878> |
| **Lidarr** | Same for music | <http://192.168.8.200:8686> |
| **Aurral** | Discover, request and play music; hands album requests to Lidarr | <http://192.168.8.201:3001> |
| **Prowlarr** | Manages indexers for all three of the above | <http://192.168.8.201:9696> |
| **Seerr** | Request page: users sign in with Jellyfin and ask for movies/shows; Radarr/Sonarr fetch them | <http://192.168.8.201:5055> |
| **Cleanuparr** | Cleans the download queue: stalled, failed-import, malware and finished/orphaned downloads | <http://192.168.8.200:11011> |
| **qBittorrent** | Download client for Radarr and Sonarr | <http://192.168.8.200:8080> |
| **qBittorrent (Lidarr)** | Download client for Lidarr only | <http://192.168.8.200:8081> |

Everything is built and kept in shape with **Ansible** (`ansible/`) and **Terraform** (`terraform/`, the VM
itself). No secrets live in this repo: they're all in 1Password and fetched at run time.

> Use the IP addresses: `*.home.arpa` names don't resolve from the Mac.

---

## Quickstart

### 1. Install the tools (once, on your Mac)

```sh
# Ansible + ansible-lint. Use Python 3.14: ansible-core crashes on Python 3.15.
uv tool install --python 3.14 ansible --with-executables-from ansible-core,ansible-lint
cd ansible && ansible-galaxy collection install -r requirements.yml && cd ..

# Terraform >= 1.17 (HashiCorp's tap; or download the signed zip from releases.hashicorp.com)
brew install hashicorp/tap/terraform

# 1Password CLI: install it, then turn on 1Password → Settings → Developer → "Integrate with 1Password CLI"
op whoami          # should print your account, not "not signed in"
```

You also need the SSH key `~/.ssh/id_ed25519`. It's already authorised on the cluster nodes and the VM.

### 2. Check that you can reach everything

```sh
cd ansible
ansible all -m ansible.builtin.ping                       # 6 hosts: 5 nodes + media-stack → "pong"
ansible-playbook playbooks/ceph.yml --tags status         # Ceph should say HEALTH_OK
```

And the apps, from anywhere on the LAN:

```sh
for u in 200:8989/ping 200:7878/ping 200:8686/ping 200:11011/health \
         201:8096/health 201:9696/ping 201:5055/api/v1/status 201:3001/api/health/live; do
  printf '%-22s ' $u; curl -fsS -m 5 http://192.168.8.${u%%:*}:${u#*:}; echo; done
curl -s -o /dev/null -w 'qbittorrent  %{http_code}\n' http://192.168.8.200:8080/   # 200
curl -s -o /dev/null -w 'qbt-lidarr   %{http_code}\n' http://192.168.8.200:8081/   # 200
```

### 3. Log in to the apps

- **Sonarr, Radarr, Lidarr, Prowlarr:** no login from the home network. Login is only required from
  outside the LAN.
- **qBittorrent:** user `admin`; password:
  `op read op://xmjfgnsondcvlqa6bovelwdztm/media-stack/qbittorrent_password`
  (the Lidarr instance on :8081 uses `qbittorrent_lidarr_password`)
- **Jellyfin:** the first visit runs a setup wizard. Create your admin user (save it in 1Password),
  then add the libraries: Movies `/data/media/movies`, Shows `/data/media/tv`,
  Anime `/data/media/anime` (type: Shows), Music `/data/media/music`.
- **Prowlarr:** add your indexers by hand. Prowlarr then pushes them to Sonarr, Radarr and Lidarr
  automatically.
- **Cleanuparr:** create its login on first visit, then add qBittorrent and the *arrs and pick
  which cleanups to enable. Steps and safe starting values are in
  [`stack/cleanuparr/README.md`](stack/cleanuparr/README.md).
- **Seerr:** after Jellyfin is set up, run Seerr's 4-step wizard once (sign in with Jellyfin, then
  connect Radarr and Sonarr). The exact values are in [`stack/seerr/README.md`](stack/seerr/README.md).

That's it: you're up and running.

---

## Everyday tasks

All Ansible commands run from `ansible/`. **Always dry-run first** (`--check --diff`). On this live
setup a healthy run reports `changed=0`.

| I want to… | Do this |
|---|---|
| Deploy a change to the stack (e.g. a new image tag in `stack/<app>/compose.yaml`) | `ansible-playbook playbooks/media-stack.yml --check --diff`, then without `--check` |
| Upgrade an app | Bump its pinned tag in `stack/<app>/compose.yaml`, open a PR, then deploy as above. Roll back by reverting the tag |
| Re-apply app settings (root folders, qBittorrent categories, Prowlarr links) | `ansible-playbook playbooks/arr-config.yml` and `playbooks/qbt-prowlarr-config.yml` |
| Run a command on a node | `ansible intel-a163f8 -a 'qm status 200'` (or `pve_nodes` for all five) |
| Check the cluster's readiness | `ansible-playbook playbooks/inventory-report.yml` (read-only) |
| Change the VM (CPU, RAM, disks) | Edit `terraform/variables.tf`, then `cd terraform && op run --env-file .env.op -- terraform plan`. Read the plan before `apply` |
| Get a secret | `op read op://xmjfgnsondcvlqa6bovelwdztm/media-stack/<field>` (fields: `sonarr_api_key`, `radarr_api_key`, `lidarr_api_key`, `prowlarr_api_key`, `aurral_api_key`, `qbittorrent_password`, `qbittorrent_lidarr_password`) |

## Remote access (Tailscale)

The five nodes, both VMs and the GL.iNet router are on a Tailscale tailnet
([`terraform/tailnet/`](terraform/tailnet/README.md) + `ansible/playbooks/tailscale.yml`). From
anywhere you reach the LAN through the router (`192.168.8.0/24`) and the lab hosts by name.
There is an exit node in Amsterdam on a USD 5/month Vultr VM (`vultr-exit-ams`), and Mullvad exit
nodes if the add-on is bought. **Nothing uses an exit node unless you switch it on for that
device**, and never on the Proxmox nodes. **No torrents through Vultr** (DMCA → account ban).
The first-time setup has manual steps (OAuth client, 1Password item, router UI), listed in order
in the tailnet README.

## Where the files are

Downloads land in `/data/torrents/<type>` and the apps move them to `/data/media/<type>`
(`<type>` = `movies`, `tv`, `anime`, `music`). Both live on the same disk, so "moving" is an
instant hardlink, not a copy. App settings are in `/opt/media-stack/config/<app>` on the VM.

## Don't

- Don't run `ceph.yml --tags osds`. It **wipes disks**, and it's only for adding a new disk to Ceph.
  It refuses without `-e confirm_destroy=<disk serial>`.
- Don't `terraform apply` a plan that says **replace** or **destroy** for VM 200 (Terraform blocks
  destroying it anyway).
- Don't `docker compose down` the stack, and don't reboot nodes casually. Ceph is fine with one node down,
  but not two.
- Don't commit secrets, `.env`, `*/secrets.env` or `terraform.tfstate`. They're gitignored for a
  reason.

## More detail

| Doc | Read it for |
|---|---|
| [`docs/media-stack.md`](docs/media-stack.md) | Operator runbook: architecture, backup/restore, upgrades, troubleshooting, follow-ups |
| [`ansible/README.md`](ansible/README.md) | Every playbook, tags, rebuild-from-scratch order, safety rules, secrets |
| [`terraform/README.md`](terraform/README.md) | VM 200 as code: API token, import, plan/apply |
| [`terraform/tailnet/README.md`](terraform/tailnet/README.md) | Tailscale: policy, auth keys, Vultr exit node, router, Mullvad; bootstrap order |
| `stack/<app>/README.md` | Per-app notes (e.g. Sonarr's anime setup, Jellyfin hardware transcoding) |
| [`CLAUDE.md`](CLAUDE.md) | Rules for AI-assisted changes (attribution, secrets) |
