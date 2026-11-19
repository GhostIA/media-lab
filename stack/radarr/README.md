# Radarr (movies)

| | |
|---|---|
| Image | `lscr.io/linuxserver/radarr:7.0.3.10918-ls328` (pinned; bump deliberately) |
| URL | http://192.168.8.200:7878 (health: `/ping`) |
| Config | `${CONFIG_ROOT}/radarr` → `/config` (`/opt/media-stack/config/radarr` on the VM) |
| Data | `${DATA_ROOT}` → `/data` (same path in every container, so imports are hardlinks) |
| Root folder | `/data/media/movies` |
| API key | 1Password `op://xmjfgnsondcvlqa6bovelwdztm/media-stack/radarr_api_key` |

## Files

`stack/compose.yaml` (project root), `stack/.env.example` (shared env) and `stack/deploy.sh` come from
the stack-skeleton unit. Validate this service alone with:
`cd stack && docker compose -f compose.yaml -f radarr/compose.yaml --env-file .env config -q`.

- `compose.yaml`: the `radarr` service, merged into the `media-stack` project by `stack/deploy.sh`
  (`-f` per service, run from `stack/`). `CONFIG_ROOT`/`DATA_ROOT` are required (compose fails if unset).
- `secrets.env.tpl`: `RADARR__AUTH__APIKEY` as an `op://` reference. `deploy.sh` renders it with
  `op inject` into `secrets.env` (mode 600) on the VM. That file is git-ignored and optional: without
  it Radarr generates its own key on first start (stored in `config.xml`).
- Root folder `/data/media/movies`: added through the API, only if missing, by the Ansible playbook
  `ansible/playbooks/arr-config.yml` (role `arr_config`). Run it from the Mac in `ansible/` after the
  container is healthy: `ansible-playbook playbooks/arr-config.yml`. See its header.

## Auth

`RADARR__AUTH__METHOD=Forms` with `RADARR__AUTH__REQUIRED=DisabledForLocalAddresses`: no login from the
LAN, a forms login otherwise. The UI keeps its own port so an OIDC reverse proxy (oauth2-proxy + Auth0)
can front it later without app changes. When that proxy is added:
- unpublish `7878` (or bind it to `127.0.0.1`), otherwise LAN clients bypass the proxy;
- proxied requests come from a private Docker IP, so Radarr's own login is skipped for them: the proxy
  is then the only auth layer (or switch `RADARR__AUTH__REQUIRED` to `Enabled`).

## Download client (manual, once qBittorrent is up)

Settings → Download Clients → `+` → qBittorrent:

| Field | Value |
|---|---|
| Host | `qbittorrent` (compose service name; same default network) |
| Port | `8080` |
| Username / Password | qBittorrent WebUI login (from 1Password) |
| Category | `movies` (qBittorrent saves it to `/data/torrents/movies`) |
| Remove completed | as preferred; imports are hardlinks, so seeding continues |

Leave Remote Path Mappings empty: both containers see `/data` at the same path.

Settings → Media Management: enable *Use Hardlinks instead of Copy* (default on) and *Rename Movies*.

## Indexers

Added automatically by Prowlarr's app sync (Prowlarr → Settings → Apps → Radarr, server
`http://radarr:7878`, API key from 1Password).

## Quality profiles

Follow the TRaSH Guides Radarr setup:
- Quality settings and profiles: https://trash-guides.info/Radarr/radarr-setup-quality-profiles/
- Custom formats: https://trash-guides.info/Radarr/Radarr-collection-of-custom-formats/

Recyclarr can sync these later; not part of this stack yet.
