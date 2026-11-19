#!/bin/sh
# DESTRUCTIVE: wipe a node's extra disk, format ext4, export over NFS, add as cluster storage.
# The disk is identified by serial number; the script refuses if the serial doesn't match.
# usage: nfs-setup.sh <node> <serial>
#   e.g. nfs-setup.sh intel-91c45d WY21Q28J
# Result: /srv/nfs/<node> exported to 192.168.8.0/24, PVE storage "nfs-<node>".
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
node=$1; serial=$2
[ -n "$node" ] && [ -n "$serial" ] || { echo "usage: $0 <node> <serial>" >&2; exit 1; }
ip=$(grep -v '^#' "$DIR/nodes.txt" | awk -v t="$node" '$1==t{print $2}')
[ -n "$ip" ] || { echo "unknown node $node" >&2; exit 1; }

"$DIR/pvessh.sh" "$node" "set -e
dev=\$(lsblk -dnpo NAME,SERIAL | awk -v s='$serial' '\$2==s{print \$1}')
[ -n \"\$dev\" ] || { echo 'no disk with serial $serial'; exit 1; }
findmnt -rno SOURCE | grep -q \"^\$dev\" && { echo \"\$dev is mounted, refusing\"; exit 1; }
pvs --noheadings -o pv_name 2>/dev/null | grep -q \"\$dev\" && { echo \"\$dev is an LVM PV, refusing\"; exit 1; }
echo \"wiping \$dev (serial $serial)\"
wipefs -a \$dev >/dev/null; sgdisk -Z \$dev >/dev/null 2>&1 || true
sgdisk -n1:0:0 -t1:8300 -c1:nfs-$node \$dev >/dev/null
partprobe \$dev 2>/dev/null || blockdev --rereadpt \$dev; udevadm settle
part=\$(lsblk -lnpo NAME \$dev | sed -n 2p)
mkfs.ext4 -q -F -m 0 -L nfs-${node#intel-} \$part
uuid=\$(blkid -s UUID -o value \$part)
mkdir -p /srv/nfs/$node
grep -q \"\$uuid\" /etc/fstab || echo \"UUID=\$uuid /srv/nfs/$node ext4 defaults,nofail 0 2\" >> /etc/fstab
systemctl daemon-reload; mount /srv/nfs/$node
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq nfs-kernel-server >/dev/null
line='/srv/nfs/$node 192.168.8.0/24(rw,sync,no_subtree_check,no_root_squash)'
grep -qF \"/srv/nfs/$node \" /etc/exports || echo \"\$line\" >> /etc/exports
systemctl enable --now nfs-server >/dev/null 2>&1; exportfs -ra
df -h /srv/nfs/$node | tail -1; exportfs -v | grep -A1 /srv/nfs/$node | tr -s ' \t\n' ' '; echo
echo NFS_SETUP_OK
" > /tmp/nfs-setup.$$ 2>&1 || true
grep -v -e Permanently -e NFS_SETUP_OK /tmp/nfs-setup.$$
grep -q NFS_SETUP_OK /tmp/nfs-setup.$$ || { rm -f /tmp/nfs-setup.$$; echo "disk/export step failed on $node; not adding storage" >&2; exit 1; }
rm -f /tmp/nfs-setup.$$

# Cluster-wide storage definition (run once from any node; /etc/pve is shared).
"$DIR/pvessh.sh" "$node" "pvesm status --storage nfs-$node >/dev/null 2>&1 && echo 'storage nfs-$node already defined' || \
  pvesm add nfs nfs-$node --server $ip --export /srv/nfs/$node --content images,rootdir,iso,vztmpl,backup,snippets --options vers=4.2 && echo 'storage nfs-$node added'" 2>&1 | grep -v Permanently
