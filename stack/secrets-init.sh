#!/bin/sh
# Create/fill the 1Password item that holds the media stack's app secrets. Safe to rerun:
# only fields that are missing (or empty) are added; existing values are never overwritten,
# and secret values are never printed or passed on a command line (they only travel via pipes).
# usage: secrets-init.sh
#
# Item "media-stack" (category API Credential) in vault "Lab" (xmjfgnsondcvlqa6bovelwdztm), concealed fields:
#   sonarr_api_key radarr_api_key lidarr_api_key prowlarr_api_key   32 lowercase hex chars
#   qbittorrent_password                                            32 random letters/digits
# Reference them as op://xmjfgnsondcvlqa6bovelwdztm/media-stack/<field> (e.g. in <svc>/secrets.env.tpl).
#
# env: OP_ITEM   item title (default media-stack; override only for testing)
VAULT=xmjfgnsondcvlqa6bovelwdztm
ITEM=${OP_ITEM:-media-stack}
FIELDS="sonarr_api_key radarr_api_key lidarr_api_key prowlarr_api_key qbittorrent_password"

ok()   { echo "OK   $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }

gen() {
  case "$1" in
  qbittorrent_password) openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32 ;;
  *) openssl rand -hex 16 ;;
  esac
}

# one JSON object per field on stdout: {"label":..,"value":..}; the value goes through a pipe only
new_field() {
  printf '%s\t%s\n' "$1" "$(gen "$1")" | jq -Rc 'split("\t") | {label: .[0], value: .[1]}'
}

command -v op >/dev/null || fail "op (1Password CLI) not found"
command -v jq >/dev/null || fail "jq not found"
command -v openssl >/dev/null || fail "openssl not found"
op vault get "$VAULT" >/dev/null 2>&1 || fail "cannot access vault $VAULT (is 1Password unlocked?)"

if json=$(op item get "$ITEM" --vault "$VAULT" --format json 2>/dev/null); then
  missing=""
  for f in $FIELDS; do
    v=$(printf '%s\n' "$json" | jq -r --arg f "$f" '[.fields[]? | select(.label == $f) | .value // ""][0] // ""')
    [ -n "$v" ] || missing="$missing $f"
  done
  v=""
  if [ -z "$missing" ]; then
    ok "item $ITEM: all fields present, nothing changed"
  else
    # replace only empty placeholders of the missing labels, keep every other field as is
    { printf '%s\n' "$json"; for f in $missing; do new_field "$f"; done; } \
      | jq -sc '.[0] as $item | (.[1:]) as $new | ($new | map(.label)) as $labels
          | $item | .fields = ([.fields[]? | select(.label as $l | ($labels | index($l)) == null)]
                               + ($new | map({id: .label, label: .label, type: "CONCEALED", value: .value})))' \
      | op item edit "$ITEM" --vault "$VAULT" >/dev/null \
      || fail "op item edit $ITEM"
    ok "item $ITEM: added$missing"
  fi
  json=""
else
  { for f in $FIELDS; do new_field "$f"; done; } \
    | jq -sc --arg t "$ITEM" '{title: $t, category: "API_CREDENTIAL",
        fields: map({id: .label, label: .label, type: "CONCEALED", value: .value})}' \
    | op item create --vault "$VAULT" - >/dev/null \
    || fail "op item create $ITEM"
  ok "item $ITEM: created with $FIELDS"
fi

# verify every reference resolves and looks right (values are checked, never shown)
rc=0
for f in $FIELDS; do
  v=$(op read "op://$VAULT/$ITEM/$f" 2>/dev/null)
  case "$f" in
  qbittorrent_password) [ ${#v} -ge 24 ] && good=1 || good=0 ;;
  *) [ ${#v} -eq 32 ] && [ -z "$(printf '%s' "$v" | tr -d '0-9a-f')" ] && good=1 || good=0 ;;
  esac
  if [ "$good" = 1 ]; then echo "ok $f"; else echo "FAIL $f (op read failed or bad format)" >&2; rc=1; fi
done
v=""
exit $rc
