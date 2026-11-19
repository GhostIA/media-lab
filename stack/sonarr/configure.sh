#!/bin/sh
# Configure Sonarr's root folders (TV + anime) through its v3 API. Idempotent: safe to rerun.
# Runs on the media-stack VM or from the Mac.
# usage: configure.sh [apply|status]
#   apply    (default) wait for Sonarr, add root folders /data/media/tv and /data/media/anime if missing
#   status   list the configured root folders
# env:
#   SONARR_URL      default http://192.168.8.200:8989
#   SONARR_API_KEY  API key; if unset, tried in order:
#                     1. op read $SONARR_OP_REF (default op://xmjfgnsondcvlqa6bovelwdztm/media-stack/sonarr_api_key)
#                     2. SONARR__AUTH__APIKEY in secrets.env next to this script (deployed copy on the VM)
#                     3. <ApiKey> in $SONARR_CONFIG (default /opt/media-stack/config/sonarr/config.xml),
#                        locally if readable, else over ssh to $SONARR_SSH (default media@192.168.8.200),
#                        where $SONARR_REMOTE_SECRETS (the deployed secrets.env) is tried first
#                   each candidate is checked against the API before use. The key is never printed.
SONARR_URL=${SONARR_URL:-http://192.168.8.200:8989}
SONARR_URL=${SONARR_URL%/}
SONARR_OP_REF=${SONARR_OP_REF:-op://xmjfgnsondcvlqa6bovelwdztm/media-stack/sonarr_api_key}
SONARR_CONFIG=${SONARR_CONFIG:-/opt/media-stack/config/sonarr/config.xml}
SONARR_SSH=${SONARR_SSH:-media@192.168.8.200}
SONARR_REMOTE_SECRETS=${SONARR_REMOTE_SECRETS:-/opt/media-stack/stack/sonarr/secrets.env}
SECRETS_ENV=$(cd "$(dirname "$0")" && pwd)/secrets.env
ROOT_FOLDERS="/data/media/tv /data/media/anime"

die() { echo "FAIL: $*" >&2; exit 1; }

# api METHOD PATH [JSON]: the key goes to curl via a stdin config file, so it never shows in ps.
api() {
  printf 'header = "X-Api-Key: %s"\n' "$KEY" | {
    if [ -n "$3" ]; then
      curl -sS -m 20 -K - -X "$1" -H 'Content-Type: application/json' --data "$3" \
        -w '\n%{http_code}' "$SONARR_URL/api/v3$2"
    else
      curl -sS -m 20 -K - -X "$1" -w '\n%{http_code}' "$SONARR_URL/api/v3$2"
    fi
  }
}
code_of() { printf '%s\n' "$1" | tail -n 1; }
body_of() { printf '%s\n' "$1" | sed '$d'; }

key_ok() { [ -n "$KEY" ] && [ "$(code_of "$(api GET /system/status)")" = 200 ]; }

xml_key() { sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$@" 2>/dev/null | head -n 1; }

wait_up() {
  i=0
  until curl -fsS -m 5 "$SONARR_URL/ping" 2>/dev/null | grep -q '"OK"'; do
    i=$((i + 1)); [ "$i" -ge 60 ] && die "Sonarr not answering at $SONARR_URL/ping"
    sleep 5
  done
  echo "OK: Sonarr up at $SONARR_URL"
}

find_key() {
  KEY=${SONARR_API_KEY:-}
  if [ -n "$KEY" ]; then key_ok && { echo "OK: API key from SONARR_API_KEY"; return; }
    die "SONARR_API_KEY rejected by Sonarr"; fi
  if command -v op >/dev/null 2>&1; then
    KEY=$(op read "$SONARR_OP_REF" 2>/dev/null)
    key_ok && { echo "OK: API key from 1Password"; return; }
  fi
  if [ -r "$SECRETS_ENV" ]; then
    KEY=$(sed -n 's/^SONARR__AUTH__APIKEY=//p' "$SECRETS_ENV" | head -n 1)
    key_ok && { echo "OK: API key from secrets.env"; return; }
  fi
  if [ -r "$SONARR_CONFIG" ]; then
    KEY=$(xml_key "$SONARR_CONFIG")
    key_ok && { echo "OK: API key from config.xml"; return; }
  else
    # From the Mac: the VM's deployed secrets.env (when set, config.xml has no <ApiKey>), else config.xml.
    # shellcheck disable=SC2029  # paths are meant to expand locally
    KEY=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$SONARR_SSH" \
      "{ sed -n 's/^SONARR__AUTH__APIKEY=//p' '$SONARR_REMOTE_SECRETS' 2>/dev/null; \
         sed -n 's:.*<ApiKey>\\([^<]*\\)</ApiKey>.*:\\1:p' '$SONARR_CONFIG'; } | grep . | head -n 1" 2>/dev/null)
    key_ok && { echo "OK: API key from the VM over ssh"; return; }
  fi
  die "no working API key (set SONARR_API_KEY, or check 1Password / $SONARR_CONFIG)"
}

# root folders as "path":"<p>","accessible":<bool> (compacted; unmappedFolders entries have no "accessible")
roots() { printf '%s' "$1" | tr -d ' \n\r\t' | grep -o '"path":"[^"]*","accessible":[a-z]*'; }
has_root() { roots "$1" | grep -q "^\"path\":\"$2/\{0,1\}\","; }

case "${1:-apply}" in
apply)
  wait_up
  find_key
  r=$(api GET /rootfolder); [ "$(code_of "$r")" = 200 ] || die "GET /rootfolder -> $(code_of "$r")"
  current=$(body_of "$r")
  for p in $ROOT_FOLDERS; do
    if has_root "$current" "$p"; then
      echo "OK: root folder $p already present"
      continue
    fi
    r=$(api POST /rootfolder "{\"path\":\"$p\"}")
    c=$(code_of "$r")
    case "$c" in
      200|201) echo "OK: root folder $p added" ;;
      *) body_of "$r" >&2
         [ "$c" = 400 ] && echo "hint: $p must exist on the VM (created by vm-media-stack.sh) and be writable by PUID/PGID" >&2
         die "POST /rootfolder $p -> $c" ;;
    esac
  done
  ;;
status)
  wait_up
  find_key
  r=$(api GET /rootfolder); [ "$(code_of "$r")" = 200 ] || die "GET /rootfolder -> $(code_of "$r")"
  roots "$(body_of "$r")" | sed 's/^"path":"\([^"]*\)","accessible":/root folder \1 accessible=/'
  ;;
*)
  sed -n '2,15p' "$0"; exit 2 ;;
esac
