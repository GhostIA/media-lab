#!/bin/sh
# Ceph setup for the "media" cluster. Run phases in order; each is safe to rerun.
# usage: ceph-setup.sh <phase>
#   teardown-nfs   remove the nfs-intel-* storages, unmount, undo fstab/exports   (DESTRUCTIVE)
#   install        install Ceph (tentacle, no-subscription) on every node
#   init           write ceph.conf with public/cluster network 192.168.8.0/24
#   mons           create monitor + manager on the MON_NODES
#   osds           zap and create one OSD per extra disk (by serial)        (DESTRUCTIVE)
#   pool           EC 2+1 RBD pool (host failure domain) + PVE storage
#   status         ceph -s and osd tree
DIR=$(cd "$(dirname "$0")" && pwd)
S="$DIR/pvessh.sh"
NET=192.168.8.0/24
MON_NODES="intel-1ecbc8 intel-a163f8 intel-177e78"
# node:serial of each OSD disk
#   intel-1ecbc8: T-FORCE 2TB SSD (replaced the 466GB HGST 160131RB254A260WG50J)
#   intel-177e78: Seagate ST4000LM016 4TB HDD (added 2026-11-19; 48 pending sectors at install, watch it)
OSD_DISKS="intel-1ecbc8:TPBF2312190010600040 intel-177e78:W8002A8K intel-91c45d:WY21Q28J intel-d1babf:ZDZG29LG"
POOL=media-ec
ALL_NODES=$(grep -v '^#' "$DIR/nodes.txt" | awk 'NF{print $1}')
q() { grep -v 'Permanently added'; }

case "$1" in
teardown-nfs)
  "$S" intel-1ecbc8 'for s in nfs-intel-1ecbc8 nfs-intel-91c45d nfs-intel-d1babf; do
      pvesm status --storage $s >/dev/null 2>&1 && pvesm remove $s && echo "removed storage $s"; done' 2>&1 | q
  # 1) drop client mounts everywhere, 2) stop serving, 3) unmount the backing disk
  for n in $ALL_NODES; do "$S" "$n" 'for m in /mnt/pve/nfs-intel-*; do [ -d "$m" ] || continue; umount -f -l "$m" 2>/dev/null; rmdir "$m" 2>/dev/null; done; true' 2>&1 | q; done
  for d in $OSD_DISKS; do n=${d%%:*}
    "$S" "$n" "sed -i '\\#/srv/nfs/$n #d' /etc/fstab /etc/exports 2>/dev/null
      exportfs -ua 2>/dev/null; grep -q '^/' /etc/exports 2>/dev/null && exportfs -ra || systemctl disable --now nfs-server >/dev/null 2>&1
      systemctl daemon-reload
      if findmnt -n /srv/nfs/$n >/dev/null; then umount /srv/nfs/$n || { echo \"$n: STILL MOUNTED\"; fuser -vm /srv/nfs/$n; exit 1; }; fi
      rmdir /srv/nfs/$n /srv/nfs 2>/dev/null
      echo \"$n: unmounted, fstab+exports cleaned, nfs-server \$(systemctl is-active nfs-server)\"" 2>&1 | q
  done
  true
  ;;
install)
  for n in $ALL_NODES; do echo "== $n"
    "$S" "$n" 'yes | pveceph install --repository no-subscription --version tentacle >/tmp/pveceph-install.log 2>&1; rc=$?; tail -2 /tmp/pveceph-install.log; ceph --version; exit $rc' 2>&1 | q
  done
  ;;
init)
  "$S" intel-1ecbc8 "[ -e /etc/pve/ceph.conf ] && echo 'ceph.conf exists' || pveceph init --network $NET --cluster-network $NET && echo 'ceph initialised'" 2>&1 | q
  ;;
mons)
  for n in $MON_NODES; do echo "== $n"
    "$S" "$n" "pveceph mon create 2>&1 | grep -v '^\$' | tail -4; pveceph mgr create 2>&1 | grep -v '^\$' | tail -3" 2>&1 | q
  done
  ;;
osds)
  for d in $OSD_DISKS; do n=${d%%:*}; ser=${d#*:}; echo "== $n ($ser)"
    "$S" "$n" "dev=\$(lsblk -dnpo NAME,SERIAL | awk -v s=$ser '\$2==s{print \$1}')
      if [ -z \"\$dev\" ]; then echo 'serial $ser not found'; exit 1; fi
      if findmnt -rno SOURCE | grep -q \"^\$dev\"; then echo \"\$dev is mounted, refusing\"; exit 1; fi
      if [ \"\$(ceph-volume lvm list --format json \$dev 2>/dev/null | tr -d ' \n')\" != '{}' ]; then echo \"\$dev is already an OSD\"; exit 0; fi
      echo \"wiping \$dev\"
      for p in \$(lsblk -lnpo NAME \$dev | tail -n +2); do wipefs -a \$p >/dev/null; done
      wipefs -a \$dev >/dev/null; sgdisk --zap-all \$dev >/dev/null 2>&1
      dd if=/dev/zero of=\$dev bs=1M count=200 oflag=direct status=none
      blockdev --rereadpt \$dev; udevadm settle
      if [ \$(lsblk -lno NAME \$dev | wc -l) -ne 1 ]; then echo \"\$dev still has partitions\"; exit 1; fi
      echo \"creating OSD on \$dev\"
      pveceph osd create \$dev 2>&1 | grep -v '^\$' | tail -3" 2>&1 | q
  done
  ;;
pool)
  # Erasure-coded 2+1 (RAID-5-like), failure domain = host. PVE creates $POOL-data (EC) and
  # $POOL-metadata (3x replicated, required by RBD) and one storage entry named $POOL.
  "$S" intel-1ecbc8 "ceph osd pool ls | grep -qx $POOL-data && echo 'pool $POOL-data exists' || \
      pveceph pool create $POOL --erasure-coding k=2,m=1,failure-domain=host --pg_autoscale_mode on --add_storages 1 2>&1 | grep -v '^\$' | tail -5
    echo; ceph osd pool ls detail | grep -E \"'$POOL\" | sed 's/ crush_rule.*min_size/ ... min_size/; s/ crash_replay.*//'
    echo; ceph osd erasure-code-profile get \$(ceph osd pool get $POOL-data erasure_code_profile -f json | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"erasure_code_profile\"])') | grep -E '^k=|^m=|failure'
    echo; pvesm status | grep -E '^Name|$POOL'; grep -A6 'rbd: $POOL' /etc/pve/storage.cfg" 2>&1 | q
  ;;
status)
  "$S" intel-1ecbc8 'ceph -s; echo; ceph osd tree; echo; ceph df' 2>&1 | q
  ;;
*) sed -n '2,10p' "$0"; exit 1 ;;
esac
