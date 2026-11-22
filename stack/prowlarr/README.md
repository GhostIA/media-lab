# Prowlarr

Indexer manager: indexers are configured once in Prowlarr and synced to Sonarr, Radarr and Lidarr.
Image `lscr.io/linuxserver/prowlarr` (pinned tag in `compose.yaml`).

| | |
|---|---|
| UI | `http://192.168.8.201:9696` (VM 201; the *arrs and qBittorrent it syncs to are on VM 200) |
| Cross-VM URLs | app sync `baseUrl` `http://192.168.8.200:<port>`, `prowlarrUrl` `http://192.168.8.201:9696`, download client `192.168.8.200:8080`, all set by `playbooks/qbt-prowlarr-config.yml` |
| Config | `${CONFIG_ROOT}/prowlarr` → `/config` |
| Auth | `Forms`, not required for local (LAN) addresses (`PROWLARR__AUTH__*`), ready for a later OIDC proxy |
| API key | `PROWLARR__AUTH__APIKEY` from `secrets.env` (`op inject` of `secrets.env.tpl`, 1Password `media-stack/prowlarr_api_key`) |

If `secrets.env` is absent (1Password item not created yet) Prowlarr starts anyway and generates its own key
in `config.xml`. The env file path is `prowlarr/secrets.env` because `stack/deploy.sh` passes service
files with `-f` after `stack/compose.yaml` (paths resolve against `stack/`).

## First login

Open the UI; from the LAN no login is required. Set a username/password under
Settings → General → Authentication if you want forms login enforced everywhere.

## Configure (apps + download client)

```sh
op signin                    # optional: lets the script read keys from 1Password
stack/prowlarr/configure.sh  # all | apps | downloadclient
```

- Applications **Sonarr**, **Radarr**, **Lidarr**: Full Sync, Prowlarr server `http://prowlarr:9696`,
  app server `http://sonarr:8989`, `http://radarr:7878`, `http://lidarr:8686` (compose network names).
- Download client **qBittorrent**: host `qbittorrent`, port `8080`, user `admin` (for manual grabs in Prowlarr).
  Its category is Prowlarr's default `prowlarr`, which Prowlarr creates in qBittorrent when the client is
  saved; with no save path of its own it follows qBittorrent's default save path (`/data/torrents`, so
  `/data/torrents/prowlarr` once `qbittorrent/configure.sh` has run; run that one first).

Keys come from `PROWLARR_API_KEY`, `SONARR_API_KEY`, `RADARR_API_KEY`, `LIDARR_API_KEY`, `QBT_PASSWORD`;
otherwise `op read op://xmjfgnsondcvlqa6bovelwdztm/media-stack/<svc>_api_key` (`qbittorrent_password`),
otherwise the deployed `<svc>/secrets.env` on the VM, otherwise `<ApiKey>` in
`/opt/media-stack/config/<svc>/config.xml` (over `ssh media@192.168.8.200`). An app whose port doesn't
answer yet is printed as `SKIP`; rerun the script once it is up. Keys are never printed. Existing matching
entries are left `unchanged`.

Prowlarr returns stored API keys and the qBittorrent password masked (`********`), so they can't be compared
directly: an entry that matches otherwise is checked with Prowlarr's connection test (which uses the stored
secret), and only rewritten when that test fails. A rotated key or a changed `qbittorrent_password` is thus
pushed on the next run; a secret that changed but still works (e.g. old password still accepted) is not.
`all` prints `prowlarr: OK, N SKIPped` when something was skipped.

## Indexers (manual)

No indexers are committed. Add them in the UI (Indexers → Add Indexer); for trackers behind Cloudflare
add a FlareSolverr proxy first. With Full Sync, Prowlarr pushes them to the *arrs automatically.
