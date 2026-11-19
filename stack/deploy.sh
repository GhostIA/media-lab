#!/bin/sh
# Deploy the media stack to the media-stack VM. Safe to rerun.
# usage: deploy.sh [svc...]     sync, resolve secrets, `docker compose up -d [svc...]`, then `ps`
#        deploy.sh config       validate the merged Compose files locally (`docker compose config -q`)
#
#   1. rsync stack/ -> $REMOTE_DIR on the VM (tar over ssh if the VM has no rsync); never .env or
#      */secrets.env; no --delete, so a removed service must be taken down and deleted by hand
#   2. on the VM, copy .env.example to .env only if .env is absent
#   3. for each <svc>/secrets.env.tpl: `op inject` locally and stream the result over ssh into
#      $REMOTE_DIR/<svc>/secrets.env (umask 077); resolved secrets never touch the Mac's disk
#   4. on the VM: docker compose -f compose.yaml -f <svc>/compose.yaml... --env-file .env up -d
#
# Service files are passed with -f (not include:d by compose.yaml), so relative paths inside
# <svc>/compose.yaml resolve against stack/: write `env_file: <svc>/secrets.env`.
#
# env: MEDIA_HOST      ssh target                 (default media@192.168.8.200)
#      MEDIA_SSH_OPTS  extra ssh options          (e.g. "-o IdentityAgent=none -i ~/.ssh/id_ed25519")
#      ENV_FILE        env file for `config` mode (default .env if present, else .env.example)
DIR=$(cd "$(dirname "$0")" && pwd)
MEDIA_HOST=${MEDIA_HOST:-media@192.168.8.200}
REMOTE_DIR=/opt/media-stack/stack
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10 ${MEDIA_SSH_OPTS:-}"

ok()   { echo "OK   $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }

cd "$DIR" || fail "cannot cd to $DIR"

# -f arguments: root first (it sets the project dir and name), then every service file
FILES="-f compose.yaml"
for f in */compose.yaml; do
  [ -f "$f" ] && FILES="$FILES -f $f"
done

case "$1" in
config)
  [ $# -eq 1 ] || fail "usage: deploy.sh config"
  envf=${ENV_FILE:-.env}
  [ -f "$envf" ] || envf=.env.example
  # env_file entries must exist for `config`; stand in empty files for missing secrets.env
  # (placeholders only, removed on exit, never holding resolved secrets)
  placeholders=""
  trap 'for p in $placeholders; do rm -f "$p"; done' EXIT
  trap 'exit 130' INT TERM
  for t in */secrets.env.tpl; do
    [ -f "$t" ] || continue
    s=${t%.tpl}
    [ -e "$s" ] || { : > "$s" && placeholders="$placeholders $s"; }
  done
  # shellcheck disable=SC2086
  if docker compose $FILES --env-file "$envf" config -q; then
    ok "compose config valid ($FILES --env-file $envf)"
  else
    fail "compose config invalid ($FILES --env-file $envf)"
  fi
  exit 0
  ;;
esac

# service names end up in a remote shell command, so only allow plain names
for s in "$@"; do
  case "$s" in
  ''|-*|*[!a-z0-9_-]*) fail "invalid service name: '$s'" ;;
  esac
done

echo "== sync to $MEDIA_HOST:$REMOTE_DIR"
$SSH "$MEDIA_HOST" "mkdir -p $REMOTE_DIR" || fail "ssh $MEDIA_HOST / mkdir $REMOTE_DIR"
if $SSH "$MEDIA_HOST" "command -v rsync" >/dev/null 2>&1; then
  rsync -rlptz --exclude=.env --exclude='*/secrets.env' -e "$SSH" ./ "$MEDIA_HOST:$REMOTE_DIR/" \
    || fail "rsync to $MEDIA_HOST:$REMOTE_DIR"
  ok "synced stack/ (rsync)"
else
  # no rsync on the VM: same file set over tar (no AppleDouble/xattr noise from macOS tar)
  find . -type f ! -name .env ! -path './*/secrets.env' \
    | COPYFILE_DISABLE=1 tar -cf - --no-xattrs -T - \
    | $SSH "$MEDIA_HOST" "tar -xmf - --no-same-owner -C $REMOTE_DIR" \
    || fail "tar copy to $MEDIA_HOST:$REMOTE_DIR"
  ok "synced stack/ (tar; rsync missing on VM)"
fi

echo "== shared .env"
$SSH "$MEDIA_HOST" "cd $REMOTE_DIR && if [ -f .env ]; then echo 'OK   .env exists, kept'; else cp .env.example .env && echo 'OK   .env created from .env.example'; fi" \
  || fail ".env on VM"

echo "== secrets"
for t in */secrets.env.tpl; do
  [ -f "$t" ] || continue
  svc=${t%/secrets.env.tpl}
  # held in a shell variable (memory), never written to the local disk
  resolved=$(op inject -i "$t") || fail "op inject $t"
  printf '%s\n' "$resolved" | $SSH "$MEDIA_HOST" \
    "umask 077 && mkdir -p $REMOTE_DIR/$svc && cat > $REMOTE_DIR/$svc/secrets.env.tmp && chmod 600 $REMOTE_DIR/$svc/secrets.env.tmp && mv -f $REMOTE_DIR/$svc/secrets.env.tmp $REMOTE_DIR/$svc/secrets.env" \
    || fail "write $svc/secrets.env on VM"
  resolved=""
  ok "$svc/secrets.env (mode 600)"
done

echo "== docker compose up -d $*"
# shellcheck disable=SC2086
$SSH "$MEDIA_HOST" "cd $REMOTE_DIR && docker compose $FILES --env-file .env up -d $* && docker compose $FILES --env-file .env ps" \
  || fail "docker compose up on $MEDIA_HOST"
ok "deployed ${*:-all services}"
