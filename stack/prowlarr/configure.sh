#!/bin/sh
# Configure Prowlarr through its API. Idempotent: safe to rerun, existing matching entries are left alone.
# usage: configure.sh [all|apps|downloadclient]      (default: all)
#   apps            add/update Applications Sonarr, Radarr, Lidarr (Full Sync, prowlarrUrl http://prowlarr:9696,
#                   baseUrl http://<app>:<port>); an app whose service doesn't answer yet is SKIPped
#   downloadclient  add the qBittorrent download client (host qbittorrent, port 8080)
# env:
#   PROWLARR_URL   Prowlarr URL                  (default http://192.168.8.200:9696)
#   APP_HOST       host where the app ports are published, for reachability checks (default 192.168.8.200)
#   VM_SSH         ssh target for key fallbacks  (default media@192.168.8.200)
#   QBT_USER       qBittorrent WebUI user        (default admin)
#   PROWLARR_API_KEY SONARR_API_KEY RADARR_API_KEY LIDARR_API_KEY QBT_PASSWORD
#                  credentials; each falls back to `op read op://<vault>/media-stack/<name>`, then to the
#                  deployed secrets.env on the VM, then to <ApiKey> in /opt/media-stack/config/<svc>/config.xml
# Needs curl and jq. Keys and passwords are never printed or put on a command line.
set -u
PROWLARR_URL=${PROWLARR_URL:-http://192.168.8.200:9696}
APP_HOST=${APP_HOST:-192.168.8.200}
VM_SSH=${VM_SSH:-media@192.168.8.200}
OP_ITEM=${OP_ITEM:-op://xmjfgnsondcvlqa6bovelwdztm/media-stack}
STACK_DIR=/opt/media-stack/stack
CONFIG_DIR=/opt/media-stack/config
APPS="sonarr:Sonarr:8989 radarr:Radarr:7878 lidarr:Lidarr:8686"
QBT_USER=${QBT_USER:-admin}
export QBT_USER
# an existing entry's secret field (env SECRET_FIELD: apiKey for apps, password for the download client) must
# be set and equal APP_SECRET to count as unchanged. Prowlarr returns secrets masked ("********"); then upsert
# runs the entry's connection test instead, so a rotated key/password is still detected and pushed.
SECRET_OK='([.fields[] | select(.name == env.SECRET_FIELD) | .value] | length > 0 and all(. == env.APP_SECRET or . == "********"))'
SECRET_MASKED='any(.fields[]; .name == env.SECRET_FIELD and .value == "********")'
SKIPPED=0

for t in curl jq; do command -v "$t" >/dev/null || { echo "FAIL: $t not found"; exit 1; }; done
TMP=$(mktemp -d) || exit 1
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

vm() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$VM_SSH" "$1" 2>/dev/null; }

# secret <ENV_VAR> <op field> <svc> <secrets.env key|-> [config.xml]: prints the value, empty if not found
secret() { var=$1; field=$2; svc=$3; skey=$4; xml=${5:-}
  eval "val=\${$var:-}"
  if [ -z "$val" ] && command -v op >/dev/null; then val=$(op read "$OP_ITEM/$field" 2>/dev/null) || val=; fi
  if [ -z "$val" ] && [ "$skey" != - ]; then
    val=$(vm "sed -n 's/^$skey=//p' $STACK_DIR/$svc/secrets.env 2>/dev/null | tail -n 1")
  fi
  if [ -z "$val" ] && [ -n "$xml" ]; then
    val=$(vm "sed -n 's:.*<ApiKey>\\(.*\\)</ApiKey>.*:\\1:p' $CONFIG_DIR/$svc/config.xml 2>/dev/null | head -n 1")
  fi
  printf %s "$val" | tr -d '\r\n'
}

# papi <METHOD> <path> [body on stdin]: body to $TMP/out, prints the HTTP code
papi() {
  if [ "$1" = GET ]; then
    curl -sS -o "$TMP/out" -w '%{http_code}' -H @"$TMP/hdr" "$PROWLARR_URL/api/v1/$2"
  else
    curl -sS -o "$TMP/out" -w '%{http_code}' -X "$1" -H @"$TMP/hdr" -H 'Content-Type: application/json' \
      --data-binary @- "$PROWLARR_URL/api/v1/$2"
  fi
}
errors() { jq -r 'if type == "array" then map(.errorMessage) | join("; ") else (.message // "") end' "$TMP/out" 2>/dev/null | head -c 300; }
reachable() { curl -fsS -m 5 -o /dev/null "$1" 2>/dev/null; }

prowlarr_login() {
  reachable "$PROWLARR_URL/ping" || { echo "FAIL: Prowlarr not reachable at $PROWLARR_URL"; return 1; }
  key=$(secret PROWLARR_API_KEY prowlarr_api_key prowlarr PROWLARR__AUTH__APIKEY xml)
  [ -n "$key" ] || { echo "FAIL: no Prowlarr API key found"; return 1; }
  printf 'X-Api-Key: %s\n' "$key" >"$TMP/hdr"
  code=$(papi GET system/status)
  [ "$code" = 200 ] || { echo "FAIL: Prowlarr API key rejected (HTTP $code)"; return 1; }
}

# upsert <kind> <name> <implementation> <match jq> <fields jq> [extra jq]
#   kind: applications|downloadclient; secrets come in via env APP_SECRET
upsert() { kind=$1; name=$2; impl=$3; match=$4; fields=$5; extra=${6:-.}
  [ "$(papi GET "$kind")" = 200 ] || { echo "FAIL: GET $kind"; return 1; }
  # prefer the entry with our name, else any of this implementation
  cur=$(jq -c --arg i "$impl" --arg n "$name" \
    '[.[] | select(.implementation == $i)] | (map(select(.name == $n)) + .) | first // empty' "$TMP/out")
  setf="(.fields |= map($fields)) | .enable = true | $extra"
  if [ -n "$cur" ]; then
    if printf '%s' "$cur" | jq -e "($match) and .enable == true" >/dev/null; then
      # masked secret: Prowlarr's test uses the stored value, so a passing test means the secret is still valid
      if ! printf '%s' "$cur" | jq -e "$SECRET_MASKED" >/dev/null \
         || [ "$(printf '%s' "$cur" | papi POST "$kind/test")" = 200 ]; then
        echo "$name: unchanged"; return 0
      fi
    fi
    id=$(printf '%s' "$cur" | jq -r .id)
    code=$(printf '%s' "$cur" | jq -c "$setf" | papi PUT "$kind/$id"); verb=updated
  else
    [ "$(papi GET "$kind/schema")" = 200 ] || { echo "FAIL: GET $kind/schema"; return 1; }
    body=$(jq -c --arg i "$impl" --arg n "$name" \
      '[.[] | select(.implementation == $i)] | first | del(.id) | .name = $n | .enable = true' "$TMP/out")
    [ -n "$body" ] && [ "$body" != null ] || { echo "FAIL: no $impl schema in $kind"; return 1; }
    code=$(printf '%s' "$body" | jq -c "$setf" | papi POST "$kind"); verb=added
  fi
  case "$code" in
  20?) echo "$name: $verb" ;;
  *)   echo "FAIL: $name $verb (HTTP $code): $(errors)"; return 1 ;;
  esac
}

do_apps() {
  rc=0
  for a in $APPS; do svc=${a%%:*}; rest=${a#*:}; impl=${rest%%:*}; port=${rest#*:}
    if ! reachable "http://$APP_HOST:$port/ping"; then echo "SKIP $impl: not reachable at http://$APP_HOST:$port"; SKIPPED=$((SKIPPED + 1)); continue; fi
    up=$(printf %s "$svc" | tr '[:lower:]' '[:upper:]')
    APP_SECRET=$(secret "${up}_API_KEY" "${svc}_api_key" "$svc" "${up}__AUTH__APIKEY" xml)
    if [ -z "$APP_SECRET" ]; then echo "SKIP $impl: no API key found"; SKIPPED=$((SKIPPED + 1)); continue; fi
    SECRET_FIELD=apiKey; export APP_SECRET SECRET_FIELD
    base="http://$svc:$port"
    upsert applications "$impl" "$impl" \
      "(.syncLevel == \"fullSync\") and ([.fields[] | select(.name == \"baseUrl\" or .name == \"prowlarrUrl\") | .value] | sort == ([\"$base\", \"http://prowlarr:9696\"] | sort)) and $SECRET_OK" \
      "if .name == \"prowlarrUrl\" then .value = \"http://prowlarr:9696\" elif .name == \"baseUrl\" then .value = \"$base\" elif .name == \"apiKey\" then .value = env.APP_SECRET else . end" \
      '.syncLevel = "fullSync"' || rc=1
  done
  return $rc
}

do_downloadclient() {
  if ! reachable "http://$APP_HOST:8080/"; then echo "SKIP qBittorrent: not reachable at http://$APP_HOST:8080"; SKIPPED=$((SKIPPED + 1)); return 0; fi
  APP_SECRET=$(secret QBT_PASSWORD qbittorrent_password qbittorrent QBT_PASSWORD)
  if [ -z "$APP_SECRET" ]; then echo "SKIP qBittorrent: no QBT_PASSWORD found"; SKIPPED=$((SKIPPED + 1)); return 0; fi
  SECRET_FIELD=password; export APP_SECRET SECRET_FIELD
  upsert downloadclient qBittorrent QBittorrent \
    "([.fields[] | select(.name == \"host\") | .value] == [\"qbittorrent\"]) and ([.fields[] | select(.name == \"port\") | .value] == [8080]) and ([.fields[] | select(.name == \"username\") | .value] == [env.QBT_USER]) and ([.fields[] | select(.name == \"useSsl\") | .value] | all(. != true)) and $SECRET_OK" \
    'if .name == "host" then .value = "qbittorrent" elif .name == "useSsl" then .value = false elif .name == "port" then .value = 8080 elif .name == "username" then .value = env.QBT_USER elif .name == "password" then .value = env.APP_SECRET else . end'
}

case "${1:-all}" in
apps)           prowlarr_login && do_apps ;;
downloadclient) prowlarr_login && do_downloadclient ;;
all)            prowlarr_login || exit 1
                rc=0; do_apps || rc=1; do_downloadclient || rc=1
                if [ $rc != 0 ]; then exit $rc; fi
                if [ "$SKIPPED" = 0 ]; then echo "prowlarr: OK"
                else echo "prowlarr: OK, $SKIPPED SKIPped (rerun once they are up)"; fi ;;
*)              sed -n '2,15p' "$0"; exit 2 ;;
esac
