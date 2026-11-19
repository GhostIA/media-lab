#!/bin/sh
# Switch nodes from enterprise to no-subscription repos (PVE 9 / trixie, deb822 format).
# Backs up /etc/apt/sources.list.d to /root/apt-sources-backup-<timestamp> first.
# usage: fix-repos.sh [node ...]     (default: all nodes in nodes.txt)
DIR=$(cd "$(dirname "$0")" && pwd)
CMD='set -e
d=/etc/apt/sources.list.d; b=/root/apt-sources-backup-$(date +%Y%m%d%H%M%S); cp -a $d $b; echo "backup: $b"
f=$d/pve-enterprise.sources
[ -f $f ] && ! grep -q "^Enabled: no" $f && echo "Enabled: no" >> $f
cat > $d/proxmox.sources <<EOT
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOT
cat > $d/ceph.sources <<EOT
Types: deb
URIs: http://download.proxmox.com/debian/ceph-tentacle
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOT
apt-get update 2>&1 | grep -E "^(Err|W:|E:)|Reading package lists" || true'
nodes=${*:-$(grep -v '^#' "$DIR/nodes.txt" | awk 'NF{print $1}')}
for n in $nodes; do
  echo "=================== $n"
  "$DIR/pvessh.sh" "$n" "$CMD" 2>&1 | grep -v 'Permanently added'
done
