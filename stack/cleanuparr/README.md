# Cleanuparr

Keeps the download queue clean so the *arrs don't get stuck
([Cleanuparr/Cleanuparr](https://github.com/Cleanuparr/Cleanuparr)):

- **Queue Cleaner:** removes downloads that are **stalled**, **slow**, stuck on metadata, or that
  **fail to import** in Sonarr/Radarr/Lidarr, and tells the *arr to search for another release.
- **Malware Blocker:** blocks torrents containing dangerous/fake files (`*.lnk`, `*.exe` in a "movie",
  `*.zipx`, …) using community blocklists.
- **Download Cleaner:** removes torrents that finished seeding (by ratio/time), and **orphaned**
  downloads that no *arr references any more or that have **no hardlink** into `/data/media`.

| | |
|---|---|
| URL | <http://192.168.8.200:11011> |
| Image | `ghcr.io/cleanuparr/cleanuparr:2.11.1` (official, pinned) |
| Config | `/opt/media-stack/config/cleanuparr` → `/config` (settings live in its database, set in the UI) |
| Data | `/data` at the same path as qBittorrent (needed for the hardlink/orphan checks) |

## First-run setup (in the UI, once)

On first visit Cleanuparr asks you to create its login. Save it in 1Password (item `media-stack`, or
a new one). Then under **Settings**:

1. **Download Clients** → add **qBittorrent**: host `http://qbittorrent:8080`, user `admin`, password
   `op read op://xmjfgnsondcvlqa6bovelwdztm/media-stack/qbittorrent_password`. Test, save.
   Add the Lidarr instance the same way: host `http://qbittorrent-lidarr:8081`, password
   `qbittorrent_lidarr_password`.
2. **Arrs** → add each app with its container URL and API key (`op read
   op://xmjfgnsondcvlqa6bovelwdztm/media-stack/<app>_api_key`):
   Sonarr `http://sonarr:8989`, Radarr `http://radarr:7878`, Lidarr `http://lidarr:8686`.
3. Turn on the features you want. A sensible start:
   - **Queue Cleaner:** enable *failed import* (max strikes 3), *stalled* (3), *slow* (e.g. min
     speed 100KB/s, 5 strikes). Keep "delete private torrents" **off** if you use private trackers.
   - **Malware Blocker:** enable, with the default blocklist.
   - **Download Cleaner:** start with *seeding* rules only (e.g. ratio 2 or 14 days for the
     `movies`/`tv`/`anime`/`music` categories). Leave *unlinked/orphaned* off until you've watched it
     for a while, because it deletes data.
4. Use **dry run** mode first if offered, check its logs/events, then switch it off.

Use the container names (`qbittorrent`, `sonarr`, …), not `192.168.8.200`: all services share the
compose network.

## Deploy / upgrade

```sh
cd ansible
ansible-playbook playbooks/media-stack.yml -e '{"media_stack_services": ["cleanuparr"]}' --check --diff
ansible-playbook playbooks/media-stack.yml -e '{"media_stack_services": ["cleanuparr"]}'
```

Health: `curl -fsS -o /dev/null -w '%{http_code}\n' http://192.168.8.200:11011/health` → `200`.
Upgrade: bump the tag (see the [releases](https://github.com/Cleanuparr/Cleanuparr/releases); tags have
no `v` prefix), PR, deploy. Back up `config/cleanuparr` first: the database migrates on upgrade.
