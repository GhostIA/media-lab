# Jellyfin

Media server on VM 201 (`media-apps`, `192.168.8.201`, node intel-d1babf). It reads `/data/media`
over NFS from VM 200, at the same `/data` path as everywhere else; its config and transcode cache stay
on VM 201's local disk.

| Item | Value |
|---|---|
| Image | `lscr.io/linuxserver/jellyfin:12.4ubu2604-ls60` (upstream Jellyfin v12.4 on Ubuntu 26.04, LSIO build 60) |
| Web UI | <http://192.168.8.201:8096> (own port; no proxy yet, ready for a later OIDC layer) |
| Health | `curl -fsS http://192.168.8.201:8096/health` returns `Healthy` |
| Discovery | `7359/udp` (lets LAN clients find the server) |
| Config | `${CONFIG_ROOT}/jellyfin` -> `/config` (cache in `/config/cache`, on the VM OS disk) |
| Media | `${DATA_ROOT}` -> `/data` (libraries under `/data/media`) |
| Secrets | none; the admin user is created in the first-run wizard (store its password in 1Password item `media-stack`, never in git) |

## Deploy

Normally through `stack/deploy.sh`. By hand on the VM:

```sh
cd /opt/media-stack/stack
docker compose -f compose.yaml -f jellyfin/compose.yaml up -d jellyfin
docker compose -f compose.yaml -f jellyfin/compose.yaml ps jellyfin   # running (healthy)
```

To upgrade, bump the pinned tag in `stack/jellyfin/compose.yaml` (check
<https://hub.docker.com/r/linuxserver/jellyfin/tags> for the newest `<version>ubu<ubuntu>-ls<n>` tag),
then `pull` and `up -d` again. Back up `${CONFIG_ROOT}/jellyfin` first (stop the container, the SQLite
databases are in `/config/data`).

## First-run wizard

Open <http://192.168.8.201:8096>; the wizard starts automatically.

1. **Language**: English (or your preference).
2. **User**: create the admin account. Save the password in 1Password (`media-stack` item, vault
   `xmjfgnsondcvlqa6bovelwdztm`, field e.g. `jellyfin-admin-password`).
3. **Media libraries**: add these four (each with one folder):

   | Library name | Content type | Folder |
   |---|---|---|
   | Movies | Movies | `/data/media/movies` |
   | Shows | Shows | `/data/media/tv` |
   | Anime | Shows | `/data/media/anime` |
   | Music | Music | `/data/media/music` |

   Defaults are fine. For **Anime**, optionally enable the AniDB/AniList metadata plugins later
   (Dashboard -> Plugins -> Catalog) and move them above TheTVDB/TMDb in the library's metadata
   fetcher order. Leave "Enable real time monitoring" on: Sonarr/Radarr/Lidarr hardlink files into
   these folders and Jellyfin picks them up.
4. **Metadata language / country**: as preferred (e.g. English / United States).
5. **Remote access**: keep "Allow remote connections" on (needed for LAN clients). Leave
   automatic port mapping (UPnP) **off**; external access will go through the future OIDC proxy.
6. Finish and log in.

After the wizard:

- Dashboard -> Playback -> Transcoding: **Hardware acceleration: None** (software transcoding, see
  below). The transcode path defaults to `/config/cache/transcodes`, which is correct.
- Dashboard -> Networking: when a reverse proxy is added later, put its IP in "Known proxies" and set
  the base URL there if it serves Jellyfin on a sub-path. Nothing to change now.
- Optional: in Sonarr/Radarr/Lidarr add a "Jellyfin / Emby" connection (Settings -> Connect) with an
  API key from Dashboard -> API Keys (store the key in 1Password) so libraries refresh on import.

## Transcoding: software for now (follow-up: Intel Quick Sync)

The VM runs on intel-a163f8, whose Intel UHD Graphics 630 (CoffeeLake-S GT2, `8086:3e92`,
PCI `0000:00:02.0`) could do QSV/VAAPI transcoding, but no GPU is passed into VM 200 yet, so
Jellyfin uses CPU (software) transcoding. That is enough for direct play and a few 1080p transcodes.

State checked on 2026-11-19: the host kernel (`7.0.2-6-pve`, cmdline only `quiet`) already has the
IOMMU on (PVE kernels enable `intel_iommu` by default: `/sys/class/iommu/dmar0`, `dmar1` exist, IRQ
remapping enabled) and the iGPU is **alone in IOMMU group 0**, which is good for passthrough. What is
missing is either GVT-g (no `mdev_supported_types` on `00:02.0`, `kvmgt` not loaded) or a PCI
passthrough entry on VM 200. Both need a node reboot and a change to VM 200's definition, which is
owned by `pve-tools/vm-media-stack.sh` (unit 1), so they are out of scope here.

### Option A: GVT-g (mediated vGPU; host keeps its console)

On intel-a163f8 (`pve-tools/pvessh.sh intel-a163f8 '<cmd>'`), during a maintenance window:

1. Make IOMMU explicit and enable GVT: in `/etc/default/grub` set
   `GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt i915.enable_gvt=1"`, then
   `update-grub` (if the node boots via systemd-boot, edit `/etc/kernel/cmdline` and run
   `proxmox-boot-tool refresh` instead).
2. Load the modules at boot: append `kvmgt`, `vfio`, `vfio_iommu_type1`, `vfio_pci` to
   `/etc/modules`, then `update-initramfs -u -k all`.
3. Migrate/shut down guests, reboot the node, wait for Ceph `HEALTH_OK`
   (`pve-tools/ceph-setup.sh status`; a163f8 is a MON/MGR).
4. Check: `ls /sys/bus/pci/devices/0000:00:02.0/mdev_supported_types` lists types such as
   `i915-GVTg_V5_4`. If the directory is still missing, the kernel no longer ships working GVT-g for
   this GPU; use option B.
5. Unit 1's script: `qm set 200 --hostpci0 0000:00:02.0,mdev=i915-GVTg_V5_4` and restart the VM.

### Option B: full passthrough (VM owns the iGPU; host loses its console output)

1. Same cmdline as option A without `i915.enable_gvt=1`; add `vfio`, `vfio_iommu_type1`, `vfio_pci`
   to `/etc/modules`; bind the iGPU to vfio: `echo "options vfio-pci ids=8086:3e92" >
   /etc/modprobe.d/vfio.conf` and `echo "blacklist i915" > /etc/modprobe.d/blacklist-i915.conf`;
   `update-initramfs -u -k all`; reboot as above.
2. Unit 1's script: VM 200 needs `machine: q35`, then `qm set 200 --hostpci0 0000:00:02.0,pcie=1`
   (keep the VM's virtual display as the primary GPU, i.e. do not set `x-vga=1`). Note the VM is then
   pinned to intel-a163f8 (no live migration with a passed-through device).

### Then, in the VM and Jellyfin (either option)

1. In VM 200: `ls -l /dev/dri` shows `card0`/`card1` and `renderD128`; get the render group id with
   `getent group render | cut -d: -f3`. The Debian kernel's `i915` driver handles UHD 630; installing
   `intel-media-va-driver-non-free` on the VM is not needed (the LSIO image ships its own drivers).
2. In `stack/jellyfin/compose.yaml` add:
   ```yaml
       devices:
         - /dev/dri:/dev/dri
       group_add:
         - "<render gid from step 1>"   # e.g. "993"
   ```
   and redeploy (`up -d jellyfin`).
3. Check inside the container:
   `docker exec jellyfin /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128`
   lists H.264/HEVC decode and encode entrypoints.
4. Jellyfin Dashboard -> Playback -> Transcoding: Hardware acceleration **Intel QuickSync (QSV)**
   (or VAAPI with device `/dev/dri/renderD128`); enable hardware decoding for H264, HEVC, MPEG2, VC1,
   VP8, VP9 and HEVC 10bit (UHD 630 has no AV1 decode); enable hardware encoding; leave "Enable Intel
   Low-Power H.264/HEVC encoder" off unless the GuC/HuC firmware is loaded in the VM. Save, then play a
   file at a lower bitrate and confirm `ffmpeg` uses `h264_qsv`/`hevc_qsv` in Dashboard -> Logs.
