# qBittorrent

Download client for the *arr stack. Image `lscr.io/linuxserver/qbittorrent` (pinned tag in `compose.yaml`).

| | |
|---|---|
| WebUI | `http://192.168.8.200:8080` (user `admin`) |
| Torrent port | `6881` tcp+udp |
| Config | `${CONFIG_ROOT}/qbittorrent` → `/config` |
| Data | `${DATA_ROOT}` → `/data` (same path in every container, so *arr imports are hardlinks) |

WebUI authentication stays on for every client, including the compose network (no subnet whitelist);
an OIDC reverse proxy can be put in front later without changing the app.

## Secrets

`secrets.env.tpl` holds only the 1Password reference `QBT_PASSWORD=op://…/media-stack/qbittorrent_password`.
`configure.sh` (and Prowlarr's `configure.sh`) read it; it is not passed to the container.

## First login / configure

On first start qBittorrent has no password and prints a temporary one to the container log.
`configure.sh` handles that:

```sh
op signin                      # optional: lets the script read QBT_PASSWORD from 1Password
stack/qbittorrent/configure.sh # or: QBT_PASSWORD=... stack/qbittorrent/configure.sh
```

It logs in with the permanent password, or with the temporary one from `docker logs qbittorrent`
(locally, or over `ssh media@192.168.8.200`), sets the permanent password from `QBT_PASSWORD`,
then applies the settings below. It never prints passwords and is safe to rerun (unchanged settings
are reported as `unchanged`). Env overrides: `QBT_URL`, `QBT_USER`, `VM_SSH`.

qBittorrent bans an IP for an hour after 5 failed logins. To avoid that, the script first checks
(`docker exec` over ssh) whether a password is saved in `qBittorrent.conf` and only tries the password that
can work; a ban is reported as such. On qBittorrent 5.x a successful login and most POSTs answer `204`.

To log in by hand before that, read the temporary password with
`ssh media@192.168.8.200 'docker logs qbittorrent 2>&1 | grep -i "temporary password"'`.

## Settings applied

- Default save path `/data/torrents`, no separate incomplete-downloads folder.
- Automatic Torrent Management is the default mode (torrents are placed by category), and torrents
  are relocated when their category or the category path changes.
- Categories, each with save path `/data/torrents/<category>`:

| Category | Used by |
|---|---|
| `movies` | Radarr |
| `tv` | Sonarr (TV) |
| `anime` | Sonarr (anime) |
| `music` | Lidarr |

Set the matching category in each *arr's qBittorrent download client.
