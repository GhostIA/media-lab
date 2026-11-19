#!/bin/sh
# Configure Lidarr through its API. Safe to rerun: only adds what is missing.
# usage: configure.sh [phase]
#   rootfolder   (default) add root folder /data/media/music if it is not there yet
#   status       show the configured root folders
# env:
#   LIDARR_URL               default http://192.168.8.200:8686
#   LIDARR_API_KEY           API key; else `op read` of LIDARR_API_KEY_REF; else <ApiKey> from
#                            /opt/media-stack/config/lidarr/config.xml on MEDIA_SSH over ssh
#   LIDARR_API_KEY_REF       default op://xmjfgnsondcvlqa6bovelwdztm/media-stack/lidarr_api_key
#   MEDIA_SSH                default media@192.168.8.200
#   LIDARR_ROOT              default /data/media/music
#   LIDARR_ROOT_NAME         default Music
#   LIDARR_QUALITY_PROFILE   default quality profile name (default "Any"; falls back to the first)
#   LIDARR_METADATA_PROFILE  default metadata profile name (default "Standard"; falls back to the first)
# needs: curl, jq. The API key is never printed and never passed on a command line.
set -u
LIDARR_URL=${LIDARR_URL:-http://192.168.8.200:8686}
LIDARR_URL=${LIDARR_URL%/}
LIDARR_API_KEY_REF=${LIDARR_API_KEY_REF:-op://xmjfgnsondcvlqa6bovelwdztm/media-stack/lidarr_api_key}
MEDIA_SSH=${MEDIA_SSH:-media@192.168.8.200}
LIDARR_ROOT=${LIDARR_ROOT:-/data/media/music}
LIDARR_ROOT_NAME=${LIDARR_ROOT_NAME:-Music}
LIDARR_QUALITY_PROFILE=${LIDARR_QUALITY_PROFILE:-Any}
LIDARR_METADATA_PROFILE=${LIDARR_METADATA_PROFILE:-Standard}
CONFIG_XML=/opt/media-stack/config/lidarr/config.xml

die() { echo "FAIL: $*" >&2; exit 1; }
for c in curl jq; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

get_key() {
  [ -n "${LIDARR_API_KEY:-}" ] && return 0
  if command -v op >/dev/null 2>&1; then
    LIDARR_API_KEY=$(op read "$LIDARR_API_KEY_REF" 2>/dev/null) || LIDARR_API_KEY=
    [ -n "$LIDARR_API_KEY" ] && { echo "OK: API key from 1Password"; return 0; }
  fi
  LIDARR_API_KEY=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$MEDIA_SSH" \
    "cat $CONFIG_XML 2>/dev/null || sudo -n cat $CONFIG_XML" 2>/dev/null |
    sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' | head -n 1) || LIDARR_API_KEY=
  [ -n "$LIDARR_API_KEY" ] && { echo "OK: API key from $MEDIA_SSH:$CONFIG_XML"; return 0; }
  die "no API key (set LIDARR_API_KEY, store it at $LIDARR_API_KEY_REF, or check ssh to $MEDIA_SSH)"
}

# api METHOD PATH [JSON]: the key goes to curl via a config on stdin, not argv.
api() {
  if [ $# -ge 3 ]; then
    printf 'header = "X-Api-Key: %s"\n' "$LIDARR_API_KEY" |
      curl -fsS -K - -X "$1" -H 'Content-Type: application/json' --data-binary "$3" "$LIDARR_URL/api/v1$2"
  else
    printf 'header = "X-Api-Key: %s"\n' "$LIDARR_API_KEY" |
      curl -fsS -K - -X "$1" "$LIDARR_URL/api/v1$2"
  fi
}

wait_ready() {
  i=0
  until curl -fsS -o /dev/null "$LIDARR_URL/ping" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -ge 30 ] && die "$LIDARR_URL/ping not answering after 60s"
    sleep 2
  done
  echo "OK: $LIDARR_URL is up"
}

# profile_id ENDPOINT NAME: id of the profile with that name, else the lowest id.
profile_id() {
  api GET "/$1" | jq -r --arg n "$2" \
    '((map(select(.name == $n)) | first) // (sort_by(.id) | first)) | .id // empty'
}

case "${1:-rootfolder}" in
rootfolder)
  wait_ready; get_key
  roots=$(api GET /rootfolder) || die "GET /rootfolder (wrong API key?)"
  if printf '%s' "$roots" | jq -e --arg p "$LIDARR_ROOT" \
      'any(.[]; (.path | rtrimstr("/")) == ($p | rtrimstr("/")))' >/dev/null; then
    echo "OK: root folder $LIDARR_ROOT already present"
    exit 0
  fi
  qp=$(profile_id qualityprofile "$LIDARR_QUALITY_PROFILE")
  mp=$(profile_id metadataprofile "$LIDARR_METADATA_PROFILE")
  [ -n "$qp" ] || die "no quality profile found"
  [ -n "$mp" ] || die "no metadata profile found"
  body=$(jq -n --arg name "$LIDARR_ROOT_NAME" --arg path "$LIDARR_ROOT" \
    --argjson qp "$qp" --argjson mp "$mp" \
    '{name: $name, path: $path, defaultQualityProfileId: $qp, defaultMetadataProfileId: $mp,
      defaultMonitorOption: "all", defaultNewItemMonitorOption: "all", defaultTags: []}')
  api POST /rootfolder "$body" >/dev/null || die "POST /rootfolder $LIDARR_ROOT"
  echo "OK: root folder $LIDARR_ROOT added (quality profile $qp, metadata profile $mp)"
  ;;
status)
  get_key
  roots=$(api GET /rootfolder) || die "GET /rootfolder (wrong API key?)"
  printf '%s' "$roots" | jq -r '.[] | "\(.id)\t\(.name)\t\(.path)\taccessible=\(.accessible)"'
  ;;
*)
  sed -n '2,16p' "$0"; exit 2
  ;;
esac
