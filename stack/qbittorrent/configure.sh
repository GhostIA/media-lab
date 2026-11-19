#!/bin/sh
# Configure qBittorrent through its WebUI API. Idempotent: safe to rerun, unchanged settings are skipped.
# usage: configure.sh [all|password|prefs|categories]      (default: all)
#   password    log in (permanent password, else the temporary one from `docker logs qbittorrent`)
#               and set the permanent WebUI password if it is not active yet
#   prefs       save_path=/data/torrents, no incomplete dir, Automatic Torrent Management by default
#   categories  movies tv anime music -> /data/torrents/<cat>
# env:
#   QBT_URL       WebUI URL                   (default http://192.168.8.200:8080)
#   QBT_USER      WebUI user                  (default admin)
#   QBT_PASSWORD  permanent WebUI password    (default: op read $QBT_PASSWORD_REF if op is signed in,
#                 else QBT_PASSWORD= from the deployed /opt/media-stack/stack/qbittorrent/secrets.env)
#   VM_SSH        ssh target for docker logs  (default media@192.168.8.200; unused if a local qbittorrent container exists)
# Needs curl and jq. Passwords are never printed or put on a command line.
set -u
QBT_URL=${QBT_URL:-http://192.168.8.200:8080}
QBT_USER=${QBT_USER:-admin}
QBT_PASSWORD_REF=${QBT_PASSWORD_REF:-op://xmjfgnsondcvlqa6bovelwdztm/media-stack/qbittorrent_password}
VM_SSH=${VM_SSH:-media@192.168.8.200}
SECRETS_FILE=/opt/media-stack/stack/qbittorrent/secrets.env
SAVE_ROOT=/data/torrents
CATEGORIES="movies tv anime music"

for t in curl jq; do command -v "$t" >/dev/null || { echo "FAIL: $t not found"; exit 1; }; done
TMP=$(mktemp -d) || exit 1
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
JAR="$TMP/cookies"

# api <path> <curl args...>: POST, body to $TMP/out, prints the HTTP code
api() { path=$1; shift
  set -- -sS -o "$TMP/out" -w '%{http_code}' -b "$JAR" -c "$JAR" -H "Referer: $QBT_URL" "$@"
  curl "$@" "$QBT_URL/api/v2/$path"
}
get() { curl -fsS -b "$JAR" -H "Referer: $QBT_URL" "$QBT_URL/api/v2/$1"; }
ok() { case "$1" in 200|204) return 0 ;; *) return 1 ;; esac; }   # qBittorrent >= 5.1 answers 204 for most POSTs

# login <password-from-stdin>: 0 on success, 2 if this IP is banned, 1 otherwise
# (older WebAPI: 200 "Ok." / "Fails."; 5.x: 204 on success, 401 on failure, 403 when banned)
login() {
  code=$(api auth/login --data-urlencode "username=$QBT_USER" --data-urlencode "password@-")
  case "$code" in
  204) return 0 ;;
  200) [ "$(cat "$TMP/out")" = "Ok." ] ;;
  403) return 2 ;;
  *)   return 1 ;;
  esac
}

# onvm <cmd>: run on the VM; locally if the qbittorrent container is here, else over ssh
onvm() {
  if command -v docker >/dev/null && docker inspect qbittorrent >/dev/null 2>&1; then sh -c "$1"
  else ssh -o BatchMode=yes -o ConnectTimeout=10 "$VM_SSH" "$1"; fi 2>/dev/null
}

# temporary password printed by the *current* container run (qBittorrent prints one only while no password
# is set); older runs are ignored so a stale one never costs a failed login (qBittorrent bans an IP after 5)
temp_password() {
  # shellcheck disable=SC2016 # expanded on the VM
  onvm 'docker logs --since "$(docker inspect -f "{{.State.StartedAt}}" qbittorrent)" qbittorrent 2>&1' \
    | sed -n 's/.*temporary password is provided for this session: *//p' | tail -n 1 | tr -d '\r '
}

banned() { echo "FAIL: qBittorrent has banned this IP after failed logins (WebUI ban duration, default 1h)"; }

# 0 if a WebUI password is saved in qBittorrent.conf, 1 if not, 2 if that can't be checked
password_set() {
  r=$(onvm 'docker exec qbittorrent sh -c "grep -q ^Password_PBKDF2= /config/qBittorrent/qBittorrent.conf && echo yes || echo no"')
  case "$r" in yes) return 0 ;; no) return 1 ;; *) return 2 ;; esac
}

do_password() {
  if [ -z "${QBT_PASSWORD:-}" ] && command -v op >/dev/null; then
    QBT_PASSWORD=$(op read "$QBT_PASSWORD_REF" 2>/dev/null) || QBT_PASSWORD=
  fi
  if [ -z "${QBT_PASSWORD:-}" ]; then   # deployed by stack/deploy.sh (op inject of secrets.env.tpl)
    QBT_PASSWORD=$(onvm "sed -n 's/^QBT_PASSWORD=//p' $SECRETS_FILE" | tail -n 1 | tr -d '\r')
  fi
  # each failed login counts towards qBittorrent's IP ban (5 by default): only try a password that can work
  password_set; pw=$?
  if [ "$pw" != 1 ] && [ -n "${QBT_PASSWORD:-}" ]; then
    printf %s "$QBT_PASSWORD" | login; r=$?
    [ "$r" = 0 ] && { echo "password: logged in with the permanent password (unchanged)"; return 0; }
    [ "$r" = 2 ] && { banned; return 1; }
    [ "$pw" = 0 ] && { echo "FAIL: the permanent password (QBT_PASSWORD) was rejected"; return 1; }
  fi
  tmp=$(temp_password)
  if [ -z "$tmp" ]; then
    echo "FAIL: cannot log in (no permanent password set/known, no temporary password for this container run)"
    return 1
  fi
  printf %s "$tmp" | login; r=$?
  [ "$r" = 2 ] && { banned; return 1; }
  [ "$r" = 0 ] || { echo "FAIL: the temporary password from docker logs was rejected"; return 1; }
  if [ -z "${QBT_PASSWORD:-}" ]; then
    echo "WARN: logged in with the temporary password; set QBT_PASSWORD or sign in to op to make it permanent"
    return 0
  fi
  export QBT_PASSWORD
  code=$(jq -cn '{web_ui_password: env.QBT_PASSWORD}' | api app/setPreferences --data-urlencode "json@-")
  ok "$code" || { echo "FAIL: setting the WebUI password (HTTP $code)"; return 1; }
  rm -f "$JAR"
  if printf %s "$QBT_PASSWORD" | login; then echo "password: permanent WebUI password set"
  else echo "FAIL: login with the new password failed"; return 1; fi
}

do_prefs() {
  want=$(jq -cn --arg p "$SAVE_ROOT" '{save_path: $p, temp_path_enabled: false, auto_tmm_enabled: true,
    torrent_changed_tmm_enabled: true, save_path_changed_tmm_enabled: true, category_changed_tmm_enabled: true}')
  cur=$(get app/preferences) || { echo "FAIL: reading preferences"; return 1; }
  # compare only the keys we manage; qBittorrent may report save_path with a trailing slash
  diff=$(printf '%s' "$cur" | jq -c --argjson w "$want" '
    with_entries(select(.key as $k | $w | has($k))) | .save_path |= (sub("/+$"; ""))
    | . as $c | $w | with_entries(select($c[.key] != .value))')
  [ -n "$diff" ] || { echo "FAIL: parsing preferences"; return 1; }
  if [ "$diff" = "{}" ]; then echo "prefs: unchanged"; return 0; fi
  code=$(printf '%s' "$diff" | api app/setPreferences --data-urlencode "json@-")
  if ! ok "$code"; then echo "FAIL: setPreferences (HTTP $code)"; return 1; fi
  echo "prefs: set $(printf '%s' "$diff" | jq -r 'keys | join(" ")')"
}

do_categories() {
  cats=$(get torrents/categories) || { echo "FAIL: reading categories"; return 1; }
  rc=0
  for c in $CATEGORIES; do
    want="$SAVE_ROOT/$c"
    have=$(printf '%s' "$cats" | jq -r --arg c "$c" 'if has($c) then (.[$c].savePath | sub("/+$"; "")) else "" end')
    if [ "$have" = "$want" ]; then echo "category $c: unchanged"; continue; fi
    if printf '%s' "$cats" | jq -e --arg c "$c" 'has($c)' >/dev/null; then ep=torrents/editCategory; verb=updated
    else ep=torrents/createCategory; verb=created; fi
    code=$(api "$ep" --data-urlencode "category=$c" --data-urlencode "savePath=$want")
    if ok "$code"; then echo "category $c: $verb -> $want"
    else echo "FAIL: category $c ($ep HTTP $code)"; rc=1; fi
  done
  return $rc
}

case "${1:-all}" in
password)   do_password ;;
prefs)      do_password && do_prefs ;;
categories) do_password && do_categories ;;
all)        do_password && do_prefs && do_categories && echo "qbittorrent: OK" ;;
*)          sed -n '2,14p' "$0"; exit 2 ;;
esac
