# qBittorrent (Lidarr)

Second qBittorrent instance, used only by Lidarr, so music grabs no longer wait in the same queue
as movies and TV. Radarr and Sonarr keep [`stack/qbittorrent`](../qbittorrent/README.md). Same image
tag as that instance; bump both together.

| | |
|---|---|
| WebUI | `http://192.168.8.200:8081` (user `admin`) |
| Torrent port | `6882` tcp+udp (forward it on the router like `6881`) |
| Config | `${CONFIG_ROOT}/qbittorrent-lidarr` → `/config` |
| Data | `${DATA_ROOT}` → `/data`, saves to `/data/torrents/music`, so Lidarr's imports stay hardlinks |
| Password | 1Password `media-stack/qbittorrent_lidarr_password` |

## Setup (all automated)

1. `ansible-playbook playbooks/secrets-init.yml`: creates `qbittorrent_lidarr_password`.
2. `ansible-playbook playbooks/media-stack.yml -e '{"media_stack_services": ["qbittorrent-lidarr"]}'`
3. `ansible-playbook playbooks/qbt-prowlarr-config.yml --tags qbittorrent`: on first start, logs in with
   the temporary password from `docker logs qbittorrent-lidarr` and sets the permanent one. Then it
   applies the same preferences as the main instance (save path, Automatic Torrent Management, queue
   limits) and the single category `music` → `/data/torrents/music`.
4. `ansible-playbook playbooks/arr-config.yml`: Lidarr download client `qBittorrent (Lidarr)`
   (`qbittorrent-lidarr:8081`, category `music`, priority 1).

## Moving Lidarr over from the shared instance

Lidarr's old client `qBittorrent` (`qbittorrent:8080`) was left enabled at priority 50, so new grabs
go to this instance while downloads already queued in the old one still import. When Lidarr's
Activity > Queue has no items on `qBittorrent`, delete that client in Lidarr (Settings > Download
Clients). The music torrents can keep seeding in the old instance until you remove them.

In Cleanuparr, add this instance as a second download client: host `http://qbittorrent-lidarr:8081`,
user `admin`, password from `qbittorrent_lidarr_password`.
