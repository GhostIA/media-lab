# Kickstart: *arr media stack via `/batch`

How to launch the parallel `/batch` job that builds the media stack on the `media` Proxmox cluster,
and everything the coordinator and its worker agents need to know first.

## 1. Before you run it

- [ ] Run from the repo root: `cd /Users/ghostia/media/media-lab` (`/batch` needs a git repo for worktrees).
- [ ] `gh auth status` shows you logged in as GhostIA (workers open PRs with `gh`).
- [ ] 1Password is unlocked and the `op` CLI works (`op whoami`); node logins are read from it.
- [ ] Cluster is healthy: `pve-tools/ceph-setup.sh status` shows `HEALTH_OK` and 4 OSDs up.
- [ ] `git status` is clean and `main` is pushed.

## 2. The command

Paste this into Claude Code:

```
/batch Build the *arr media stack described in docs/arr-batch-kickstart.md on the 5-node Proxmox cluster "media". Jellyfin as media server; Sonarr for TV and anime (separate root folders), Radarr for movies, Lidarr for music, Prowlarr for indexers, qBittorrent as download client. Read CLAUDE.md and docs/arr-batch-kickstart.md first and follow their conventions, suggested layout, work units and e2e recipe. Node access via pve-tools/pvessh.sh <node> <cmd>. Online sources may be used. Never commit secrets (op:// references only). Auth0 is out of scope for now: leave the web UIs ready for a later OIDC reverse-proxy layer.
```

## 3. Current state of the cluster (as of 2026-11-19)

| Item | Value |
|---|---|
| PVE cluster | `media`, 5 nodes, quorate, PVE 9.2.2 |
| Nodes | intel-1ecbc8 `.234`, intel-a163f8 `.123`, intel-177e78 `.162`, intel-91c45d `.196`, intel-d1babf `.194` (all `192.168.8.x/24`, gateway `.1`) |
| Network | one flat 1 GbE LAN on `vmbr0`; `*.home.arpa` names do **not** resolve from the Mac, so use IPs |
| Ceph | 20.2.5 tentacle, 3 MON/MGR (1ecbc8, a163f8, 177e78), 4 OSDs, `HEALTH_OK` |
| OSDs | osd.0 1.9 TB SSD (1ecbc8), osd.1 3.6 TB HDD (177e78, 48 pending sectors, watch it), osd.2/osd.3 1.8 TB HDD (91c45d, d1babf) |
| Storage | PVE storage **`media-ec`**: RBD, EC 2+1 data pool `media-ec-data` + replicated `media-ec-metadata`, content `images,rootdir`, ~5.8 TiB raw available |
| Guests | none yet, so every VMID is free |
| Known fix | `libpve-storage-perl` must be ≥ 9.1.9 for Ceph 20 keys; all nodes run 9.1.18 |

Open decisions, not for the workers to change: EC data pool `min_size` is 2 (keeps running with
one host down, smaller safety margin); Auth0/OIDC is deferred.

## 4. Conventions workers must follow

- **Attribution:** see `CLAUDE.md`: commits and PRs credit GhostIA only, with no Claude trailers or footers.
- **Secrets:** never in git. Reference 1Password with `op://` (pattern in `pve-tools/.env`); resolve at
  deploy time with `op run --env-file … -- <cmd>` or `op inject`. App API keys generated at first
  start go into 1Password, not the repo.
- **Node access:** `pve-tools/pvessh.sh <node|ip> '<command>'`. It reads passwords from 1Password and
  closes stdin (set `PVESSH_STDIN=1` to pipe input). Remote command output is the only feedback, so
  echo clear success or failure markers.
- **Script style:** POSIX `sh`, idempotent (safe to rerun), destructive steps guarded by explicit checks;
  match `pve-tools/ceph-setup.sh` (phased `case` script). Header comment with usage on every script.
- **Destructive actions:** never touch the Ceph OSDs, the boot NVMe disks, or cluster/corosync config.

## 5. Suggested architecture (defaults; workers may refine with a reason in the PR)

- **One Debian 13 VM** (e.g. VMID 200 `media-stack`) with its disks on `media-ec`, running **Docker
  Compose**. Separate OS disk (~32 GB) and data disk (sized to need, e.g. 3 TB, thin-provisioned on RBD).
  Static IP on the LAN; check it's free with `ping` first and note it in the PR.
- **Single `/data` tree** (TRaSH Guides layout) so imports are hardlinks and moves are instant:
  ```
  /data/torrents/{movies,tv,anime,music}
  /data/media/{movies,tv,anime,music}
  ```
  All containers mount `/data` at the same path, with one `PUID`/`PGID` and `umask 002`.
- **Services and default ports:** Jellyfin 8096, Sonarr 8989, Radarr 7878, Lidarr 8686, Prowlarr 9696,
  qBittorrent 8080. Sonarr gets two root folders: `/data/media/tv` and `/data/media/anime` (anime series
  type plus its own quality profile). Images: `lscr.io/linuxserver/*` or official images, pinned tags.
- **Jellyfin hardware transcoding:** only if the node's Intel iGPU can be passed through; otherwise
  software transcoding, documented as a follow-up.
- **Auth-ready:** keep each UI on its own port, so an OIDC proxy (oauth2-proxy + Caddy/Traefik with
  Auth0) can be added later without changing the apps.

## 6. Suggested work units (independent; one PR each)

Each service owns its own `stack/<service>/compose.yaml`; the root `stack/compose.yaml` only
`include:`s them, so units don't edit the same file.

| # | Unit | Files | Change |
|---|---|---|---|
| 1 | VM provisioning | `pve-tools/vm-media-stack.sh` | Create/upgrade the Debian 13 cloud-init VM on `media-ec`, install Docker, create `/data` tree |
| 2 | Stack skeleton | `stack/compose.yaml`, `stack/.env.example`, `stack/deploy.sh` | Root compose with `include:`, shared env (PUID/PGID/TZ/paths), deploy script (rsync + `op run` + `docker compose up -d`) |
| 3 | Jellyfin | `stack/jellyfin/` | Compose service, libraries for movies, TV, anime, music; HW transcoding if possible |
| 4 | Sonarr (TV + anime) | `stack/sonarr/` | Compose service, two root folders, anime profile notes |
| 5 | Radarr | `stack/radarr/` | Compose service, movies root folder |
| 6 | Lidarr | `stack/lidarr/` | Compose service, music root folder |
| 7 | Prowlarr + qBittorrent | `stack/prowlarr/`, `stack/qbittorrent/` | Compose services; qBittorrent categories match `/data/torrents/*`; Prowlarr app sync to the *arrs |
| 8 | Runbook | `docs/media-stack.md` | Architecture, URLs, first-login steps, backup/restore, upgrade procedure |

## 7. End-to-end check (each worker, for its unit)

1. Deploy: `stack/deploy.sh` (or the unit's script) against the media-stack VM.
2. On the VM: `docker compose ps` shows the unit's containers `running`/`healthy`.
3. From the Mac, the service answers over HTTP:
   ```
   curl -fsS http://<vm-ip>:8096/health        # Jellyfin -> Healthy
   curl -fsS http://<vm-ip>:8989/ping          # Sonarr   -> {"status":"OK"}
   curl -fsS http://<vm-ip>:7878/ping          # Radarr
   curl -fsS http://<vm-ip>:8686/ping          # Lidarr
   curl -fsS http://<vm-ip>:9696/ping          # Prowlarr
   curl -fsS -o /dev/null -w '%{http_code}\n' http://<vm-ip>:8080/   # qBittorrent -> 200
   ```
4. Paths: inside the container, `/data/media/<type>` and `/data/torrents/<type>` exist and are writable,
   and a test file hardlinks between them (same inode, checked with `stat -c %i`).
5. Ceph stays `HEALTH_OK` afterwards (`pve-tools/ceph-setup.sh status`).

Unit 1 must land first in practice (the VM is the deploy target). If the VM doesn't exist yet, the other
units should verify with `docker compose config` and note in the PR that live e2e is pending unit 1.
