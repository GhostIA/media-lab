# Lidarr (music)

- Image: `lscr.io/linuxserver/lidarr:3.1.6.5079-ls49` (stable, same digest as `latest` on 2026-11-19).
  Upgrade by bumping the pinned tag and redeploying.
- UI/API: `http://192.168.8.200:8686`, health: `curl -fsS http://192.168.8.200:8686/ping`.
- Config: `${CONFIG_ROOT}/lidarr` (`/opt/media-stack/config/lidarr`), data: `${DATA_ROOT}` mounted as `/data`.
- Auth: Forms login, disabled for local (LAN) addresses. The UI stays on its own port so an OIDC
  reverse proxy can be put in front later without changing Lidarr.

## API key

`secrets.env.tpl` holds only the 1Password reference
`op://xmjfgnsondcvlqa6bovelwdztm/media-stack/lidarr_api_key`. `stack/deploy.sh` resolves it with
`op inject` directly into `lidarr/secrets.env` (mode 600) on the VM; Lidarr then uses it via
`LIDARR__AUTH__APIKEY`. Without `secrets.env` Lidarr generates its own key in `config.xml`.

## Root folder

| Name | Path | Defaults |
|---|---|---|
| Music | `/data/media/music` | quality profile `Any`, metadata profile `Standard` (first of each if missing) |

`./configure.sh` adds it through `/api/v1/rootfolder` only if missing (rerun is a no-op);
`./configure.sh status` lists the root folders. The key comes from `LIDARR_API_KEY`, else
`op read`, else `<ApiKey>` in the VM's `config.xml` over ssh.

## Download client (qBittorrent)

Settings > Download Clients > + > qBittorrent:

| Field | Value |
|---|---|
| Host | `qbittorrent` (compose service name on the shared default network) |
| Port | `8080` |
| Username / Password | qBittorrent WebUI login (from 1Password) |
| Category | `music` (qBittorrent saves it to `/data/torrents/music`) |

Because torrents (`/data/torrents/music`) and the library (`/data/media/music`) are on the same
`/data` filesystem, imports are hardlinks: instant, no extra space. Leave "Use Hardlinks instead
of Copy" enabled (Settings > Media Management). Indexers are pushed by Prowlarr app sync.
