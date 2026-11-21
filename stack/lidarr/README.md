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

`ansible-playbook playbooks/arr-config.yml` (from `ansible/`, role `arr_config`) adds it through
`/api/v1/rootfolder` only if missing (rerun is a no-op) and prints the root folders present. The key
comes from 1Password (`op://<vault>/media-stack/lidarr_api_key`).

## Download client (qBittorrent)

Managed by `ansible-playbook playbooks/arr-config.yml` (entry `qBittorrent (Lidarr)`, priority 1); the values, for reference:

| Field | Value |
|---|---|
| Host | `qbittorrent-lidarr` (Lidarr's own instance, compose service name on the shared network) |
| Port | `8081` |
| Username / Password | `admin` / `qbittorrent_lidarr_password` (1Password) |
| Category | `music` (qBittorrent saves it to `/data/torrents/music`) |

Because torrents (`/data/torrents/music`) and the library (`/data/media/music`) are on the same
`/data` filesystem, imports are hardlinks: instant, no extra space. Leave "Use Hardlinks instead
of Copy" enabled (Settings > Media Management). Indexers are pushed by Prowlarr app sync.
