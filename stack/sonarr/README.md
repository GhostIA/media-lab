# Sonarr (TV + anime)

`lscr.io/linuxserver/sonarr` (pinned v4 tag in `compose.yaml`), port **8989**, config in
`${CONFIG_ROOT}/sonarr`, the whole `${DATA_ROOT}` tree mounted at `/data` so imports are hardlinks.

| File | Purpose |
|---|---|
| `compose.yaml` | service `sonarr`; healthcheck on `/ping` |
| `secrets.env.tpl` | `SONARR__AUTH__APIKEY` as an `op://` reference; `stack/deploy.sh` resolves it on the VM into `secrets.env` (mode 600). Optional: without it Sonarr generates its own key in `config.xml` |
| `configure.sh` | idempotent API setup: adds the two root folders if missing (`configure.sh status` lists them) |

## Deploy and configure

```sh
stack/deploy.sh sonarr                # sync, resolve secrets, up -d sonarr
SONARR_URL=http://192.168.8.200:8989 stack/sonarr/configure.sh
curl -fsS http://192.168.8.200:8989/ping   # {"status":"OK"}
```

`configure.sh` takes the API key from `SONARR_API_KEY`, else `op read` of the 1Password field
`media-stack/sonarr_api_key`, else `secrets.env` next to the script, else `<ApiKey>` in
`/opt/media-stack/config/sonarr/config.xml` (locally, or over ssh to `media@192.168.8.200` where the deployed `secrets.env` is tried first). Every candidate is checked against the API first,
and the key is never printed.

The 1Password field `sonarr_api_key` (item `media-stack`) is created by `stack/secrets-init.sh`;
`op inject` needs it before the first deploy. `stack/.gitignore` keeps `*/secrets.env` out of git.

Auth: `Forms` with `DisabledForLocalAddresses` (no login from the LAN). Set the admin user/password
on first visit. Put the later OIDC reverse proxy in front of port 8989 without changing the app.

## Root folders

| Root folder | Series Type | Quality profile | qBittorrent category | Download path |
|---|---|---|---|---|
| `/data/media/tv` | Standard | e.g. `WEB-1080p` | `tv` | `/data/torrents/tv` |
| `/data/media/anime` | **Anime** | separate anime profile (below) | `anime` | `/data/torrents/anime` |

When adding an anime series: choose root folder `/data/media/anime` **and** set
**Series Type = Anime** (absolute episode numbering, anime naming). Sonarr has no per-root-folder
default, so pick both on the Add Series screen.

### Anime quality profile (follow-up)

Create a separate profile for anime, e.g. `Remux-1080p - Anime`, following the TRaSH Guides:

- Profile: https://trash-guides.info/Sonarr/sonarr-setup-quality-profiles-anime/
- Release-group custom formats (Anime BD/Web tiers, `v0`..`v4`, dual audio, etc.):
  https://trash-guides.info/Sonarr/sonarr-collection-of-custom-formats/#anime
- Anime naming scheme: https://trash-guides.info/Sonarr/Sonarr-recommended-naming-scheme/

Importing the custom formats (manually or with Recyclarr) is a follow-up; it's not automated here.

## Download client (qBittorrent)

Settings > Download Clients > + > qBittorrent:

- Host `qbittorrent`, port `8080` (container name on the compose network), credentials from the
  qBittorrent unit.
- Category `tv`. qBittorrent saves the `tv` category to `/data/torrents/tv`.
- For anime, add a **second** qBittorrent client entry with category `anime`
  (`/data/torrents/anime`) and give the anime series a tag that the anime client is restricted to
  (Download Client > Tags), so each series type lands in its own category.

Both paths are under the same `/data` mount as the media folders, so completed downloads are
hardlinked into `/data/media/{tv,anime}`, not copied. No remote path mappings are needed.

Indexers come from Prowlarr (app sync from `http://192.168.8.201:9696` on VM 201 to `http://192.168.8.200:8989`).
