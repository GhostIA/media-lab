#!/bin/sh
# Configure Radarr through its API after the container is up. Safe to rerun (idempotent).
# usage: configure.sh [phase]
#   check        GET /ping and verify the API key works
#   rootfolder   add root folder /data/media/movies if it is missing
#   all          check + rootfolder (default)
# env:
#   RADARR_URL      default http://192.168.8.200:7878
#   RADARR_API_KEY  API key; if unset or rejected: `op read` of $RADARR_KEY_REF, else over ssh to
#                   $RADARR_SSH the container's RADARR__AUTH__APIKEY or <ApiKey> in
#                   $RADARR_CONFIG_XML. First key the API accepts wins. The key is never printed.
#   RADARR_KEY_REF  default op://xmjfgnsondcvlqa6bovelwdztm/media-stack/radarr_api_key
#   RADARR_SSH      default media@192.168.8.200
#   RADARR_CONFIG_XML default /opt/media-stack/config/radarr/config.xml
# Download client (qBittorrent) and quality profiles are set up by hand / by Prowlarr: see README.md.
set -eu

RADARR_URL=${RADARR_URL:-http://192.168.8.200:7878}
RADARR_KEY_REF=${RADARR_KEY_REF:-op://xmjfgnsondcvlqa6bovelwdztm/media-stack/radarr_api_key}
RADARR_SSH=${RADARR_SSH:-media@192.168.8.200}
RADARR_CONFIG_XML=${RADARR_CONFIG_XML:-/opt/media-stack/config/radarr/config.xml}
MOVIES_ROOT=/data/media/movies

die() { echo "FAIL: $*" >&2; exit 1; }

KEY_OK=
# key_works: 0 if $RADARR_API_KEY is non-empty and accepted by the API.
key_works() {
  [ -n "$RADARR_API_KEY" ] || return 1
  printf 'X-Api-Key: %s\n' "$RADARR_API_KEY" | curl -fsS -o /dev/null -H @- "$RADARR_URL/api/v3/system/status" 2>/dev/null
}

# load_key: try env, then 1Password, then the running container's env / config.xml over ssh,
# and keep the first key the API accepts (a stale or mismatched key falls through to the next).
load_key() {
  [ -z "$KEY_OK" ] || return 0
  RADARR_API_KEY=${RADARR_API_KEY:-}
  if ! key_works && command -v op >/dev/null 2>&1; then
    RADARR_API_KEY=$(op read "$RADARR_KEY_REF" 2>/dev/null) || RADARR_API_KEY=
  fi
  if ! key_works; then
    RADARR_API_KEY=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$RADARR_SSH" \
      "docker exec radarr printenv RADARR__AUTH__APIKEY 2>/dev/null ||
       sed -n 's:.*<ApiKey>\\(.*\\)</ApiKey>.*:\\1:p' '$RADARR_CONFIG_XML'" 2>/dev/null) || RADARR_API_KEY=
  fi
  key_works || die "no working API key for $RADARR_URL (tried RADARR_API_KEY, $RADARR_KEY_REF, ssh $RADARR_SSH)"
  KEY_OK=1
}

# api METHOD PATH [JSON]: the key goes to curl on stdin (-H @-), never on the command line.
api() {
  if [ $# -ge 3 ]; then
    printf 'X-Api-Key: %s\n' "$RADARR_API_KEY" | curl -fsS -X "$1" -H @- \
      -H 'Content-Type: application/json' --data "$3" "$RADARR_URL/api/v3$2"
  else
    printf 'X-Api-Key: %s\n' "$RADARR_API_KEY" | curl -fsS -X "$1" -H @- "$RADARR_URL/api/v3$2"
  fi
}

do_check() {
  curl -fsS "$RADARR_URL/ping" >/dev/null || die "$RADARR_URL/ping not answering"
  load_key
  echo "OK: radarr up at $RADARR_URL, API key accepted"
}

do_rootfolder() {
  load_key
  folders=$(api GET /rootfolder) || die "GET /rootfolder failed"
  if printf '%s' "$folders" | grep -Eq "\"path\": *\"$MOVIES_ROOT/?\""; then
    echo "OK: root folder $MOVIES_ROOT already present"
    return 0
  fi
  api POST /rootfolder "{\"path\":\"$MOVIES_ROOT\"}" >/dev/null || die "could not add root folder $MOVIES_ROOT"
  echo "OK: root folder $MOVIES_ROOT added"
}

case "${1:-all}" in
  check)      do_check ;;
  rootfolder) do_rootfolder ;;
  all)        do_check; do_rootfolder ;;
  *)          awk 'NR>1 && /^#/{print; next} NR>1{exit}' "$0" >&2; exit 2 ;;
esac
