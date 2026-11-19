# Runbook: *arr media stack

Operator guide for the media stack on the `media` Proxmox cluster: Jellyfin, Sonarr (TV + anime),
Radarr, Lidarr, Prowlarr and qBittorrent in one Docker Compose project on VM 200.
How it was built: [arr-batch-kickstart.md](arr-batch-kickstart.md). Repo rules: [CLAUDE.md](../CLAUDE.md).

All commands run from the repo root on the Mac unless the prompt says `media@vm`.

## 1. Architecture

```
Mac (repo checkout, op CLI, gh)
 │  ssh media@192.168.8.200            pve-tools/pvessh.sh <node> '<cmd>'  (PVE nodes)
 ▼
VM 200 "media-stack"  (Debian 13, 192.168.8.200, runs on intel-a163f8 / 192.168.8.123)
 └─ docker compose project "media-stack"   (/opt/media-stack/stack, one -f per stack/<svc>/compose.yaml)
     ├─ jellyfin     :8096   media server            reads  /data/media
     ├─ sonarr       :8989   TV + anime               /data  (torrents -> media, hardlinks)
     ├─ radarr       :7878   movies                   /data
     ├─ lidarr       :8686   music                    /data
     ├─ prowlarr     :9696   indexers -> app sync to sonarr/radarr/lidarr
     └─ qbittorrent  :8080   downloads into           /data/torrents/<category>
 │
 ├─ OS disk   32G  (ext4 /)                ─┐
 └─ data disk 3T   (ext4 /data)            ─┴─ PVE storage "media-ec" (RBD)
                                                └─ Ceph EC 2+1 pool media-ec-data (host failure domain)
                                                   4 OSDs on 1ecbc8, 177e78, 91c45d, d1babf
```

`/data` layout (TRaSH Guides). One filesystem, mounted at the same path `/data` in every container,
so an import is a hardlink (instant, no extra space) instead of a copy:

```
/data
├── torrents/{movies,tv,anime,music}   qBittorrent categories write here (seeding stays here)
└── media/{movies,tv,anime,music}      *arr root folders; Jellyfin libraries read here
```

Owner `1000:1000` (`media`), dirs `2775`, containers run with `PUID=1000 PGID=1000 UMASK=002`.

## 2. VM facts

| Item | Value |
|---|---|
| VMID / name | `200` / `media-stack` |
| Node | intel-a163f8 (`192.168.8.123`) |
| OS | Debian 13 (trixie) cloud-init image, docker-ce + compose plugin |
| IP | `192.168.8.200/24`, gateway `192.168.8.1` (static, via cloud-init) |
| Sizing | 4 vCPU, 5 GiB RAM |
| Disks | OS 32G + data 3T (thin), both on `media-ec`; data disk is ext4 mounted at `/data` |
| Login | `ssh media@192.168.8.200` (key `~/.ssh/id_ed25519.pub`; `media` is uid/gid 1000, in `docker` group) |
| Stack checkout | `/opt/media-stack/stack` (rsynced from `stack/` by `stack/deploy.sh`, not a git clone) |
| App configs | `/opt/media-stack/config/<service>` |
| Media + downloads | `/data/{torrents,media}/{movies,tv,anime,music}` |
| Shared env | `stack/.env.example`: `PUID=1000 PGID=1000 UMASK=002 TZ=America/Chicago DATA_ROOT=/data CONFIG_ROOT=/opt/media-stack/config` |
| Secrets on VM | `/opt/media-stack/stack/<svc>/secrets.env` (mode 600, rendered by `op inject` at deploy, gitignored) |

## 3. Service URLs

LAN only, plain HTTP, one port per app (so an auth proxy can be put in front later, see section 10).

| Service | URL | Health check (from the Mac) | Expect |
|---|---|---|---|
| Jellyfin | http://192.168.8.200:8096 | `curl -fsS http://192.168.8.200:8096/health` | `Healthy` |
| Sonarr | http://192.168.8.200:8989 | `curl -fsS http://192.168.8.200:8989/ping` | `{"status":"OK"}` |
| Radarr | http://192.168.8.200:7878 | `curl -fsS http://192.168.8.200:7878/ping` | `{"status":"OK"}` |
| Lidarr | http://192.168.8.200:8686 | `curl -fsS http://192.168.8.200:8686/ping` | `{"status":"OK"}` |
| Prowlarr | http://192.168.8.200:9696 | `curl -fsS http://192.168.8.200:9696/ping` | `{"status":"OK"}` |
| qBittorrent | http://192.168.8.200:8080 | `curl -fsS -o /dev/null -w '%{http_code}\n' http://192.168.8.200:8080/` | `200` |

All at once:

```sh
for p in 8096/health 8989/ping 7878/ping 8686/ping 9696/ping 8080/; do
  printf '%-12s ' "$p"; curl -fsS -m 5 -o /dev/null -w '%{http_code}\n' "http://192.168.8.200:$p" || echo FAIL
done
```

Container state on the VM:

```sh
ssh media@192.168.8.200 'docker compose -p media-stack ps'
```

## 4. Bring-up from scratch

Prerequisites: `op whoami` works, `pve-tools/ceph-setup.sh status` is `HEALTH_OK`, and
`192.168.8.200` does not answer `ping` (nothing else holds the IP).

| # | Step | Command |
|---|---|---|
| 1 | Download the Debian 13 cloud image to the node | `pve-tools/vm-media-stack.sh image` |
| 2 | Create VM 200 (disks on `media-ec`, cloud-init user/IP/key) | `pve-tools/vm-media-stack.sh create` |
| 3 | Boot it | `pve-tools/vm-media-stack.sh start` |
| 4 | Install Docker, format/mount `/data`, create the `/data` tree and `/opt/media-stack` | `pve-tools/vm-media-stack.sh bootstrap` |
| 5 | Check VM, disks, docker, `/data` | `pve-tools/vm-media-stack.sh status` |
| 6 | Create the 1Password item `media-stack` with generated API keys / password (idempotent) | `stack/secrets-init.sh` |
| 7 | Sync `stack/`, render `secrets.env`, `docker compose up -d` | `stack/deploy.sh` |
| 8 | qBittorrent: password, save path, categories `movies tv anime music` | `stack/qbittorrent/configure.sh` |
| 9 | Sonarr: root folders `/data/media/tv` + `/data/media/anime`, download client | `stack/sonarr/configure.sh` |
| 10 | Radarr: root folder `/data/media/movies`, download client | `stack/radarr/configure.sh` |
| 11 | Lidarr: root folder `/data/media/music`, download client | `stack/lidarr/configure.sh` |
| 12 | Prowlarr: app sync to Sonarr, Radarr, Lidarr | `stack/prowlarr/configure.sh` |
| 13 | Jellyfin first-run wizard (below) | browser |
| 14 | Add indexers in Prowlarr (manual, below) | browser |

Every script is safe to rerun; see its header comment for options. `stack/deploy.sh` takes optional
service names (`stack/deploy.sh sonarr radarr`) to deploy only those.

Order matters for 8-12: qBittorrent must be configured before the *arrs add it as a download client,
and the *arrs must be up before Prowlarr syncs to them.

**Jellyfin first-run wizard** (http://192.168.8.200:8096):

1. Language, then create the admin user. Store it in 1Password yourself (it is not generated by
   `secrets-init.sh`).
2. Add libraries:

   | Library | Content type | Folder |
   |---|---|---|
   | Movies | Movies | `/data/media/movies` |
   | Shows | Shows | `/data/media/tv` |
   | Anime | Shows | `/data/media/anime` |
   | Music | Music | `/data/media/music` |

3. Leave "Allow remote connections" on (needed for LAN clients), finish, sign in.

**Indexers in Prowlarr:** Indexers → Add Indexer → pick and test each one → Save. Then
Settings → Apps → Sync App Indexers (or wait for the automatic sync) and confirm they appear under
Settings → Indexers in Sonarr, Radarr and Lidarr. Indexer credentials stay in Prowlarr's config only;
if you want them in 1Password, store them there by hand.

## 5. First login per app

The *arrs start with `<APP>__AUTH__METHOD=Forms` and `<APP>__AUTH__REQUIRED=DisabledForLocalAddresses`,
so from the LAN they open without a login prompt. Set a user/password on first visit if the app asks
(Settings → General → Authentication); keep it in 1Password. API keys are fixed by
`<APP>__AUTH__APIKEY` from 1Password, so do not regenerate them in the UI (the env var wins on restart
and anything synced with the old key breaks).

Credentials live in 1Password item **`media-stack`** in vault **Lab** (`xmjfgnsondcvlqa6bovelwdztm`):

| Field | Used by |
|---|---|
| `sonarr_api_key` | Sonarr API, Prowlarr app sync |
| `radarr_api_key` | Radarr API, Prowlarr app sync |
| `lidarr_api_key` | Lidarr API, Prowlarr app sync |
| `prowlarr_api_key` | Prowlarr API |
| `qbittorrent_password` | qBittorrent web UI (user `admin`), *arr download client |

Read one value (prints it, so only in your own terminal):

```sh
op read "op://xmjfgnsondcvlqa6bovelwdztm/media-stack/sonarr_api_key"
```

Use one without printing it:

```sh
curl -fsS -H "X-Api-Key: $(op read 'op://xmjfgnsondcvlqa6bovelwdztm/media-stack/sonarr_api_key')" \
  http://192.168.8.200:8989/api/v3/system/status
```

| App | First login |
|---|---|
| Jellyfin | Admin user from the wizard (section 4) |
| Sonarr / Radarr / Lidarr / Prowlarr | No prompt from the LAN; API key in the field above |
| qBittorrent | User `admin`, password `qbittorrent_password` (set by `stack/qbittorrent/configure.sh`) |

## 6. Sonarr: TV vs anime

One Sonarr instance, two root folders:

| | TV | Anime |
|---|---|---|
| Root folder | `/data/media/tv` | `/data/media/anime` |
| Series Type (when adding a series) | Standard | **Anime** (absolute episode numbers) |
| Quality profile | default HD profile | separate anime profile (e.g. `Anime`, dual-audio/fansub releases allowed) |
| qBittorrent category | `tv` → `/data/torrents/tv` | `anime` → `/data/torrents/anime` |
| Jellyfin library | Shows | Anime |

When adding an anime series: choose root folder `/data/media/anime`, Series Type **Anime** and the anime
profile, and give it the `anime` tag. Check in qBittorrent that anime grabs land under category `anime`:
Sonarr's download client uses one category, so anime routing relies on a second qBittorrent download
client (category `anime`, restricted to tag `anime`) as set up by `stack/sonarr/configure.sh`; if it is
missing, add it under Settings → Download Clients. A series
added to the wrong root folder can be moved with Series → Edit → Root Folder (Sonarr moves the files).

## 7. Backup and restore

What needs backing up: **app configs** (`/opt/media-stack/config`, small: databases, settings, Jellyfin
metadata). Secrets are in 1Password; the stack definition is in git. Media is re-downloadable and is
**not** backed up (see below).

**Option A: tar the configs** (consistent: stop the stack first, SQLite databases are open while running).

```sh
ssh media@192.168.8.200 'docker compose -p media-stack stop
  sudo tar -C /opt/media-stack -czf /tmp/media-config-$(date +%F).tgz config; rc=$?
  docker compose -p media-stack start            # always restart, even if tar failed
  ls -lh /tmp/media-config-*.tgz; exit $rc'
scp 'media@192.168.8.200:/tmp/media-config-*.tgz' ~/Backups/      # copy off the VM (off Ceph)
ssh media@192.168.8.200 'sudo rm -f /tmp/media-config-*.tgz'
```

Restore onto a fresh VM (after section 4 steps 1-6):

```sh
scp ~/Backups/media-config-YYYY-MM-DD.tgz media@192.168.8.200:/tmp/
ssh media@192.168.8.200 'set -e
  docker compose -p media-stack stop 2>/dev/null || true
  sudo tar -C /opt/media-stack -xzf /tmp/media-config-YYYY-MM-DD.tgz
  sudo chown -R 1000:1000 /opt/media-stack/config'
stack/deploy.sh
```

API keys come back from 1Password via the env vars, so the restored configs and the keys match.

**Option B: `vzdump` of VM 200 without the data disk.** Mark the 3T disk `backup=0` once (keep its
other options; check the bus/name with `qm config 200`):

```sh
pve-tools/pvessh.sh intel-a163f8 'qm config 200 | grep -E "^(scsi|virtio|sata)[0-9]"'
pve-tools/pvessh.sh intel-a163f8 'qm set 200 --scsi1 media-ec:vm-200-disk-1,backup=0'   # adjust to the line above
pve-tools/pvessh.sh intel-a163f8 'vzdump 200 --mode snapshot --compress zstd --storage <backup-storage>'
```

`media-ec` only holds `images,rootdir`, so `<backup-storage>` must be a storage with `backup`
content that is **not** on the same Ceph pool (e.g. a PBS or an NFS share off-cluster). None exists
yet: until one does, use option A. Restore: `qmrestore <archive> 200 --storage media-ec`, then
re-attach or recreate the data disk.

**What media loss means on EC 2+1.** The data disk is RBD on the EC 2+1 pool `media-ec-data`: each
object is 2 data + 1 parity chunk on 3 different hosts.

| Event | Result |
|---|---|
| One OSD host down / one OSD dead | No data loss; Ceph rebuilds onto the remaining OSDs. With `min_size 2` I/O keeps running, but with **no redundancy left** until recovery finishes |
| Second OSD/host failure before recovery completes | PGs on both lose data: the RBD image (and the ext4 on it) is damaged; treat `/data` as lost |
| Only 4 OSD hosts | After one permanent loss, 3 hosts remain = exactly k+m, so the pool is still placeable but has no spare host |

Ceph redundancy is not a backup. If `/data` is lost: recreate the data disk, rerun
`pve-tools/vm-media-stack.sh bootstrap` for the tree, restore configs, and let the *arrs re-search
(they still know every series/movie/album that was monitored: Wanted → Missing → Search All).

## 8. Upgrade procedure

Images are pinned (`lscr.io/linuxserver/<app>:<version>`), never `latest`.

1. Pick the new tag from the image's tags page / release notes (read breaking changes, especially
   database migrations).
2. Back up configs (section 7, option A). An *arr database migration cannot be undone by rolling the
   tag back.
3. Bump the tag in `stack/<svc>/compose.yaml` on a branch, open a PR, merge.
4. Deploy just that service from `main`:
   ```sh
   stack/deploy.sh sonarr
   ```
5. Verify: health check from section 3, `docker compose -p media-stack ps` shows it `running`
   (`healthy` where a healthcheck exists), and the app's System → Status shows the new version.
6. Rollback: revert the tag commit, `stack/deploy.sh <svc>`. If the new version migrated the database,
   also restore `/opt/media-stack/config/<svc>` from the backup taken in step 2 (stop the service first).

VM OS updates: `ssh media@192.168.8.200 'sudo apt-get update && sudo apt-get -y upgrade'`; reboot if
the kernel changed (containers come back by their restart policy).

## 9. Troubleshooting

| Symptom | Check / fix |
|---|---|
| Imports copy instead of hardlink (slow, double space) | Source and target must be on the same filesystem under the single `/data` mount, with the same path in qBittorrent and the *arrs. No per-folder mounts like `/downloads` or `/tv`. Test: `ssh media@192.168.8.200 'touch /data/torrents/tv/t && ln /data/torrents/tv/t /data/media/tv/t && stat -c %i /data/torrents/tv/t /data/media/tv/t; rm -f /data/torrents/tv/t /data/media/tv/t'` (same inode twice) |
| *arr "Access denied" / "folder not writable" | Everything is owned by `1000:1000`, dirs `2775`, `PUID=1000 PGID=1000 UMASK=002`. Fix: `ssh media@192.168.8.200 'sudo chown -R 1000:1000 /data /opt/media-stack/config && sudo find /data -type d -exec chmod 2775 {} +'` |
| Container restarting | `ssh media@192.168.8.200 'docker compose -p media-stack logs --tail 100 <svc>'` |
| Deploy fails at secrets | `op whoami`; check the field exists in item `media-stack`; rerun `stack/secrets-init.sh` (idempotent) |
| *arr can't reach qBittorrent / Prowlarr sync fails | Rerun `stack/qbittorrent/configure.sh`, then the *arr's `configure.sh`, then `stack/prowlarr/configure.sh` |
| `/data` slow or I/O errors | Ceph health: `pve-tools/ceph-setup.sh status` (expect `HEALTH_OK`, 4 OSDs up/in) |
| VM won't start | `pve-tools/pvessh.sh intel-a163f8 'qm status 200; qm start 200'`; Ceph must have quorum (3 MONs) |

**osd.1 pending sectors.** osd.1 (Seagate 4TB HDD on intel-177e78, serial `W8002A8K`) had 48 pending
sectors when it was added. Check it regularly; a rising count means replace the disk before it fails:

```sh
pve-tools/pvessh.sh intel-177e78 'smartctl -A $(lsblk -dnpo NAME,SERIAL | awk "\$2==\"W8002A8K\"{print \$1}") | grep -Ei "pending|realloc|uncorrect"'
pve-tools/ceph-setup.sh status
```

## 10. Follow-ups

| Item | Notes |
|---|---|
| Jellyfin HW transcoding | intel-a163f8 has an Intel UHD 630. Needs `intel_iommu=on` on the node's kernel cmdline + reboot (check with `dmesg \| grep -e DMAR -e IOMMU`), then either full iGPU passthrough to VM 200 or GVT-g (mediated device, `i915.enable_gvt=1` + `kvmgt`). Inside the VM, pass `/dev/dri` to the Jellyfin container (`devices: [/dev/dri:/dev/dri]`, render group) and enable QSV/VA-API in Dashboard → Playback. Passthrough pins VM 200 to intel-a163f8 (no live migration). Until then: software transcoding |
| OIDC reverse proxy | oauth2-proxy + Caddy or Traefik with Auth0 in front of each port; then bind the app ports to localhost / the proxy network only and switch the *arrs to `External` auth or keep Forms behind the proxy. Apps need no changes beyond that |
| EC `min_size` | Currently 2 on `media-ec-data`: stays writable with one host down but with zero margin. Decide between availability (2) and safety (3 = pause I/O until recovery) |
| VPN for qBittorrent | If wanted: route only the qBittorrent container through a VPN container (e.g. gluetun, `network_mode: service:gluetun`), move port 8080 to the VPN container, and update the *arr download client host |
| Off-cluster backup storage | Add a PBS or NFS backup target so section 7 option B can run on a schedule |
