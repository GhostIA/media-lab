#!/bin/sh
# Join a standalone PVE node to an existing cluster through the PVE API.
# Passwords go from 1Password straight into curl's stdin: they are never put
# on a command line, printed, or written to disk.
# usage: join.sh <node> [cluster-node]     (cluster-node defaults to intel-1ecbc8)
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
lookup() { grep -v '^#' "$DIR/nodes.txt" | awk -v t="$1" '$1==t || $2==t' | head -1; }
pw()     { op item get "$1" --fields password --reveal | tr -d '\n'; }
json()   { python3 -I -c "import json,sys; print(json.load(sys.stdin)$1)"; }

node=$(lookup "$1");               [ -n "$node" ] || { echo "unknown node: $1" >&2; exit 1; }
clus=$(lookup "${2:-intel-1ecbc8}"); [ -n "$clus" ] || { echo "unknown cluster node: $2" >&2; exit 1; }
name=$(echo "$node" | awk '{print $1}'); ip=$(echo "$node" | awk '{print $2}'); item=$(echo "$node" | awk '{print $3}')
cip=$(echo "$clus" | awk '{print $2}'); citem=$(echo "$clus" | awk '{print $3}')

if "$DIR/pvessh.sh" "$name" test -e /etc/pve/corosync.conf 2>/dev/null; then
  echo "$name is already in a cluster; refusing." >&2; exit 1
fi
if [ -n "$("$DIR/pvessh.sh" "$name" 'ls /etc/pve/qemu-server /etc/pve/lxc' 2>/dev/null | grep conf)" ]; then
  echo "$name has guests; check VMID clashes before joining. Refusing." >&2; exit 1
fi

fp=$(openssl s_client -connect "$cip:8006" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)
echo "cluster node $cip fingerprint: $fp"

login=$(pw "$item" | curl -sk --fail https://$ip:8006/api2/json/access/ticket \
          --data-urlencode "username=root@pam" --data-urlencode "password@-")
ticket=$(echo "$login" | json '["data"]["ticket"]')
csrf=$(echo "$login"   | json '["data"]["CSRFPreventionToken"]')

echo "joining $name ($ip) -> $cip ..."
pw "$citem" | curl -sk --fail -X POST https://$ip:8006/api2/json/cluster/config/join \
  -H "CSRFPreventionToken: $csrf" -b "PVEAuthCookie=$ticket" \
  --data-urlencode "hostname=$cip" --data-urlencode "fingerprint=$fp" \
  --data-urlencode "link0=$ip" --data-urlencode "password@-"
echo

# Poll the cluster node until the new member shows up (up to ~2 min).
i=0; while [ $i -lt 24 ]; do
  if "$DIR/pvessh.sh" "${2:-intel-1ecbc8}" pvecm nodes 2>/dev/null | grep -q " $name"; then
    echo "$name joined."; "$DIR/pvessh.sh" "${2:-intel-1ecbc8}" pvecm status 2>/dev/null | grep -E "Nodes:|Quorate:"; exit 0
  fi
  i=$((i+1)); sleep 5
done
echo "$name not visible in cluster after 2 min; check 'journalctl -u pve-cluster -u corosync' on $name" >&2; exit 1
