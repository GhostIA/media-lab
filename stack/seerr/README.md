# Seerr

Request portal for the stack: users sign in with their **Jellyfin** account, browse/search, and
request movies or shows; Seerr hands the request to **Radarr** (movies) or **Sonarr** (TV, anime),
which find and download them. It's the merged successor of Jellyseerr and Overseerr
([seerr-team/seerr](https://github.com/seerr-team/seerr)).

| | |
|---|---|
| URL | <http://192.168.8.200:5055> |
| Image | `ghcr.io/seerr-team/seerr:v3.5.2` (official, pinned) |
| Config | `/opt/media-stack/config/seerr` on the VM → `/app/config` (owned 1000:1000; the image runs as uid 1000) |
| Data | none: Seerr only talks to the other apps' APIs |

## Deploy / upgrade

From `ansible/`:

```sh
ansible-playbook playbooks/media-stack.yml -e '{"media_stack_services": ["seerr"]}' --check --diff
ansible-playbook playbooks/media-stack.yml -e '{"media_stack_services": ["seerr"]}'
```

Upgrade: bump the tag in `compose.yaml` (see the [releases](https://github.com/seerr-team/seerr/releases)),
PR, deploy as above, check `curl -fsS http://192.168.8.200:5055/api/v1/status`. Roll back by
reverting the tag (back up `config/` first: Seerr migrates its database on upgrade).

## First-run setup (in the browser, once)

Do the Jellyfin setup wizard first (Seerr signs in with a Jellyfin admin account).

1. Open <http://192.168.8.200:5055> and choose **Jellyfin**.
2. Jellyfin URL: `http://jellyfin:8096` (container name on the stack network), then sign in with the
   Jellyfin admin account. Sync libraries: Movies, Shows, Anime (and skip Music: Seerr doesn't
   request music).
3. **Radarr**: hostname `radarr`, port `7878`, API key
   `op read op://xmjfgnsondcvlqa6bovelwdztm/media-stack/radarr_api_key`, root folder
   `/data/media/movies`, mark it default.
4. **Sonarr**: hostname `sonarr`, port `8989`, API key
   `op read op://xmjfgnsondcvlqa6bovelwdztm/media-stack/sonarr_api_key`, root folder
   `/data/media/tv`; under *Anime*, set root folder `/data/media/anime` (and the anime quality
   profile if you created one), mark it default.
5. Finish. Users can now sign in with their Jellyfin accounts.

Use the container names (`radarr`, `sonarr`, `jellyfin`), not `192.168.8.200`: all services share
the compose network.

## Auth

Seerr has its own login (Jellyfin accounts), so it's usable from anywhere the port is reachable. Like
the other UIs it keeps its own port, ready for the later OIDC reverse proxy.
