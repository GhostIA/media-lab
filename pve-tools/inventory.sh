#!/bin/sh
# Read-only cluster-readiness check of every node in nodes.txt (or the nodes given as args).
# usage: inventory.sh [node ...]
DIR=$(cd "$(dirname "$0")" && pwd)
CMD='hostname -f; pveversion
echo "-- cluster:"; pvecm status 2>&1 | grep -E "^Name:|Nodes:|Quorate:|Error"
echo "-- guests:"; qm list 2>/dev/null | awk "NR>1{printf \"vm%s(%s) \", \$1,\$3}"; pct list 2>/dev/null | awk "NR>1{printf \"ct%s(%s) \", \$1,\$2}"; echo
echo "-- storage:"; pvesm status 2>/dev/null | awk "NR>1{print \"  \"\$1,\$2,\$3}"
echo "-- hosts:"; grep -Ev "^#|^$|::|ip6" /etc/hosts
echo "-- net:"; ip -br a | grep -Ev "^(lo|tap|fwbr|fwpr|fwln|veth)"
echo "-- time:"; timedatectl | grep -i synchronized
echo "-- repos:"; grep -rh "^URIs\|^Components\|^deb" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | sort -u'
nodes=${*:-$(grep -v '^#' "$DIR/nodes.txt" | awk 'NF{print $1}')}
for n in $nodes; do
  echo "=================== $n"
  "$DIR/pvessh.sh" "$n" "$CMD" 2>&1 | grep -v 'Permanently added'
done
