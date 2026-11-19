#!/bin/sh
# SSH to a PVE node using its password from 1Password (nothing is printed or saved).
# usage: pvessh.sh <node-name|ip> [command...]
#   e.g. pvessh.sh intel-a163f8 pvecm status
#        pvessh.sh 192.168.8.123          # interactive shell
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
target=$1; shift
line=$(grep -v '^#' "$DIR/nodes.txt" | awk -v t="$target" '$1==t || $2==t' | head -1)
[ -n "$line" ] || { echo "unknown node: $target (see $DIR/nodes.txt)" >&2; exit 1; }
ip=$(echo "$line" | awk '{print $2}'); item=$(echo "$line" | awk '{print $3}')
vault=$(op item get "$item" --format json | python3 -I -c 'import json,sys;print(json.load(sys.stdin)["vault"]["id"])')
user=$(op item get "$item" --fields username)
export OP_REF="$vault/$item" SSH_ASKPASS="$DIR/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
if [ $# -eq 0 ]; then
  exec ssh -o PubkeyAuthentication=no -o IdentityAgent=none -o ConnectTimeout=8 "${user:-root}@$ip"
elif [ -n "$PVESSH_STDIN" ]; then
  exec ssh -o PubkeyAuthentication=no -o IdentityAgent=none -o ConnectTimeout=8 "${user:-root}@$ip" "$@"
else
  exec ssh -o PubkeyAuthentication=no -o IdentityAgent=none -o ConnectTimeout=8 "${user:-root}@$ip" "$@" </dev/null
fi
