# Aurral (music discovery and requests)

- Image: `ghcr.io/lklynet/aurral:3.0.1` (same digest as `latest` on 2026-11-21). Upgrade by bumping
  the pinned tag and redeploying. Read the release notes first: plugins are beta and can break
  between releases.
- UI/API: `http://192.168.8.200:3001`, health: `curl -fsS http://192.168.8.200:3001/api/health/live`
  (`{"status":"ok"}`).
- Config/database: `${CONFIG_ROOT}/aurral` (`/opt/media-stack/config/aurral`), mounted as `/config`.
  Data: `${DATA_ROOT}` mounted as `/data` (same path as every other service).
- Runs as `PUID:PGID` (1000:1000). Aurral ignores `UMASK`, so its files are 644/755, which Jellyfin
  can still read.

## Auth and API key

On first start, open the UI and create the admin account. Store its password in 1Password yourself;
`playbooks/secrets-init.yml` does not create it. Users and roles live in Settings > Users. Auto-login from the
local network works only for direct connections, not through a proxy. Aurral has native OIDC
(`OIDC_*` variables) for when the OIDC proxy comes in.

`secrets.env.tpl` sets `AURRAL_API_KEY` from `op://xmjfgnsondcvlqa6bovelwdztm/media-stack/aurral_api_key`
(64 hex chars, created by `ansible-playbook playbooks/secrets-init.yml`; Aurral refuses to start with
fewer than 32). `playbooks/media-stack.yml` renders it into `aurral/secrets.env` (mode 600) on the VM. While it is set, Settings > General cannot
rotate the key.

## Folders

| Folder | Path | Kind |
|---|---|---|
| Library folder | `/data/media/aurral` (`LIBRARY_FOLDER`; created by `playbooks/media-host.yml`) | Aurral's own downloads, flows, playlists |
| Lidarr music | `/data/media/music` | Read-only folder: Aurral plays it and never changes it |

In **Settings > Library**, add `/data/media/music` as a read-only folder. To play
Aurral's downloads in Jellyfin, add `/data/media/aurral` to the Jellyfin music library.

## Connect Lidarr (plugin)

Aurral 3 has no Lidarr settings of its own. Lidarr is an official plugin that becomes a download
source:

1. **Lidarr > Settings > Metadata**: set **Tag Audio Files with Metadata** to *All files*, then
   **Retag** existing artists. Without MusicBrainz tags Aurral matches by name and misses some albums.
2. **Aurral > Settings > Plugins > Install from a link > use the official plugins > Lidarr**
   (version 0.3.0 or later).
3. Open the plugin and fill in:
   - URL: `http://lidarr:8686` (compose service name)
   - API key: `op read op://xmjfgnsondcvlqa6bovelwdztm/media-stack/lidarr_api_key`
   - Root folder for new artists: `/data/media/music`
4. Select **Test**, then turn the plugin on. To have Lidarr handle album requests first, drag Lidarr
   to the top in **Settings > Downloads > Download clients**.

Lidarr then grabs requested albums with its own indexers and qBittorrent. Aurral finds them in the
read-only folder. Single tracks and flow tracks come from Aurral's other sources (for example the
built-in yt-dlp), not from Lidarr.

**Spotify:** Aurral can import Spotify playlists (Import playlist). Lidarr's own
**Settings > Import Lists > Spotify** lists also still work alongside it.
