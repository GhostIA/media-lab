#!/bin/sh
# Debian 13 (trixie) cloud-init VM "media-stack" (VMID 200) for the *arr media stack, disks on media-ec.
# Run phases in order; each is safe to rerun.
# usage: vm-media-stack.sh <phase>
#   image      download the Debian 13 genericcloud amd64 qcow2 to the node, verify SHA512
#   create     create VM 200 (OS disk 32G + 3T thin data disk on media-ec, cloud-init user media)
#   start      start the VM and wait until SSH answers as media@$VM_IP
#   bootstrap  over SSH: docker-ce + compose plugin, qemu-guest-agent, ext4 /data (format only if blank),
#              /data/{torrents,media}/{movies,tv,anime,music} and /opt/media-stack/{config,stack} as 1000:1000
#   status     VM state on the node + VM_READY check, disks and /data tree from the VM
# env: MEDIA_SSH_PUBKEY (default ~/.ssh/id_ed25519.pub; the private key is the same path without .pub)
#      VM_IP (default 192.168.8.200), VM_SSH_OPTS (extra ssh options for reaching the VM)
# Never touches Ceph OSDs, node boot disks or cluster/corosync config.
DIR=$(cd "$(dirname "$0")" && pwd)
S="$DIR/pvessh.sh"
NODE=intel-a163f8
VMID=200
NAME=media-stack
STORAGE=media-ec
OS_SIZE=32G
DATA_SIZE_GB=3072
VM_IP=${VM_IP:-192.168.8.200}
GW=192.168.8.1
DNS=192.168.8.1
VM_USER=media
PUBKEY=${MEDIA_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}
IMG=debian-13-genericcloud-amd64.qcow2
IMG_URL=https://cloud.debian.org/images/cloud/trixie/latest
IMG_DIR=/var/lib/vz/import   # = volume local:import/$IMG (storage "local" has content "import")
q() { grep -v 'Permanently added'; }
# run a command on $NODE, filter its output and keep its exit status (POSIX sh has no pipefail)
rs() { out=$("$S" "$NODE" "$1" 2>&1); rc=$?; printf '%s\n' "$out" | q; return $rc; }
# The Mac's ssh config uses the 1Password agent; bypass it and use the key file directly.
vssh() {
  # shellcheck disable=SC2086
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    -o IdentityAgent=none -o IdentitiesOnly=yes -i "${PUBKEY%.pub}" $VM_SSH_OPTS "$VM_USER@$VM_IP" "$@"
}

case "$1" in
image)
  rs "set -e; mkdir -p $IMG_DIR; cd $IMG_DIR
    curl -fsSL -o SHA512SUMS.new $IMG_URL/SHA512SUMS
    want=\$(awk '\$2==\"$IMG\"{print \$1}' SHA512SUMS.new)
    [ -n \"\$want\" ] || { echo 'FAIL: $IMG not in SHA512SUMS'; exit 1; }
    if [ -f $IMG ] && [ \"\$(sha512sum $IMG | cut -d' ' -f1)\" = \"\$want\" ]; then
      echo 'OK: $IMG present, checksum matches latest'; rm -f SHA512SUMS.new; exit 0; fi
    echo 'downloading $IMG'
    curl -fsSL -o $IMG.part $IMG_URL/$IMG
    if [ \"\$(sha512sum $IMG.part | cut -d' ' -f1)\" != \"\$want\" ]; then echo 'FAIL: checksum mismatch'; rm -f $IMG.part; exit 1; fi
    mv $IMG.part $IMG; mv SHA512SUMS.new SHA512SUMS
    echo \"OK: $IMG verified (sha512 \$(echo \$want | cut -c1-16)...)\"; ls -lh $IMG"
  ;;
create)
  [ -r "$PUBKEY" ] || { echo "FAIL: public key $PUBKEY not readable"; exit 1; }
  PVESSH_STDIN=1 "$S" "$NODE" "cat > /root/$NAME.pub" < "$PUBKEY" 2>&1 | q
  rs "set -e
    # guard: VMID must be free cluster-wide or already be ours, on this node
    owner=\$(pvesh get /cluster/resources --type vm --output-format json | python3 -c 'import json,sys
for r in json.load(sys.stdin):
    if r.get(\"vmid\")==$VMID: print(r.get(\"node\",\"\"), r.get(\"name\",\"\"))')
    if [ -n \"\$owner\" ]; then
      [ \"\$owner\" = \"$NODE $NAME\" ] || { echo \"FAIL: VMID $VMID exists as '\$owner' (expected '$NODE $NAME'), refusing\"; exit 1; }
      echo 'OK: VM $VMID $NAME exists'
    else
      # guard: the IP must be unused before we claim it
      if ping -c2 -W1 $VM_IP >/dev/null 2>&1; then echo 'FAIL: $VM_IP answers ping, refusing'; exit 1; fi
      if ip neigh show $VM_IP | grep -Eq 'REACHABLE|STALE|DELAY|PROBE|PERMANENT'; then
        echo \"FAIL: $VM_IP has a neighbour entry: \$(ip neigh show $VM_IP)\"; exit 1; fi
      echo 'OK: $VM_IP is free (no ping reply, no neighbour entry)'
      [ -f $IMG_DIR/$IMG ] || { echo 'FAIL: image missing, run the image phase first'; exit 1; }
      qm create $VMID --name $NAME --ostype l26 --machine q35 --cpu host --cores 4 --sockets 1 \
        --memory 5120 --balloon 0 --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 \
        --agent enabled=1 --onboot 1 --serial0 socket --vga serial0 \
        --scsi0 $STORAGE:0,import-from=local:import/$IMG,discard=on,iothread=1,ssd=1 \
        --ide2 $STORAGE:cloudinit --boot order=scsi0 >/dev/null
      echo 'OK: VM $VMID created'
    fi
    cfg=\$(qm config $VMID)
    # settings that are safe to (re)apply
    qm set $VMID --ciuser $VM_USER --sshkeys /root/$NAME.pub --ciupgrade 0 \
      --ipconfig0 ip=$VM_IP/24,gw=$GW --nameserver $DNS --searchdomain home.arpa >/dev/null
    echo \"\$cfg\" | grep -q '^scsi1:' || { qm set $VMID --scsi1 $STORAGE:$DATA_SIZE_GB,discard=on,iothread=1,ssd=1 >/dev/null; echo 'OK: data disk scsi1 ${DATA_SIZE_GB}G added'; }
    # grow the OS disk to $OS_SIZE (never shrinks)
    cur=\$(qm config $VMID | sed -n 's/^scsi0:.*size=\([0-9]*\)G.*/\1/p')
    if [ -n \"\$cur\" ] && [ \"\$cur\" -lt ${OS_SIZE%G} ]; then qm disk resize $VMID scsi0 $OS_SIZE >/dev/null; echo 'OK: scsi0 resized to $OS_SIZE'; fi
    qm cloudinit update $VMID >/dev/null 2>&1 || true
    echo '-- config'; qm config $VMID | grep -E '^(name|cores|cpu|memory|balloon|machine|scsihw|net0|agent|onboot|scsi0|scsi1|ide2|ipconfig0|nameserver|ciuser):'
    echo 'CREATE_OK'"
  ;;
start)
  rs "qm status $VMID | grep -q running && echo 'OK: already running' || { qm start $VMID && echo 'OK: started'; }" || exit 1
  printf 'waiting for ssh %s@%s ' "$VM_USER" "$VM_IP"
  i=0; while [ $i -lt 60 ]; do
    if vssh true 2>/dev/null; then echo; echo 'START_OK: ssh answers'; exit 0; fi
    printf .; sleep 5; i=$((i + 1))
  done
  echo; echo "FAIL: no ssh to $VM_USER@$VM_IP after 5 min"; exit 1
  ;;
bootstrap)
  vssh 'sudo sh -s' <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null 2>&1 || true   # let first-boot apt/user setup finish

# --- packages: qemu-guest-agent + docker-ce from the official Docker apt repo (trixie)
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1 || ! dpkg -s qemu-guest-agent >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -yq ca-certificates curl qemu-guest-agent >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<SRC
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
SRC
  apt-get update -qq
  apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1
systemctl start qemu-guest-agent   # static unit, started by udev when the virtio port appears
id -nG media | grep -qw docker || usermod -aG docker media
echo "OK: $(docker --version), compose $(docker compose version --short), qemu-ga $(dpkg-query -W -f='${Version}' qemu-guest-agent)"

# --- data disk (PVE scsi1): format ONLY if blkid finds nothing (no fs, no partition table)
DEV=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
[ -b "$DEV" ] || { echo "FAIL: data disk $DEV not found"; exit 1; }
if blkid -p "$DEV" >/dev/null 2>&1; then
  echo "OK: $DEV already has $(blkid -p -s TYPE -o value "$DEV" 2>/dev/null || echo 'a signature'), not formatting"
else
  echo "formatting blank $DEV as ext4"
  mkfs.ext4 -q -L data -m 0 -E nodiscard "$DEV"
fi
[ "$(blkid -s TYPE -o value "$DEV")" = ext4 ] || { echo "FAIL: $DEV is not ext4, refusing to mount"; exit 1; }
UUID=$(blkid -s UUID -o value "$DEV")
mkdir -p /data
if ! grep -q "^UUID=$UUID " /etc/fstab; then
  grep -Eq '^[^#[:space:]]+[[:space:]]+/data[[:space:]]' /etc/fstab && { echo "FAIL: /etc/fstab already has another /data entry"; exit 1; }
  echo "UUID=$UUID /data ext4 defaults,noatime,nofail,x-systemd.device-timeout=30s 0 2" >> /etc/fstab
  systemctl daemon-reload
  echo "OK: fstab entry added for UUID=$UUID"
fi
mountpoint -q /data || mount /data
echo "OK: /data mounted ($(df -h --output=size /data | tail -1 | tr -d ' '))"

# --- directory tree, TRaSH layout, one owner 1000:1000, setgid group-writable
for d in /data /data/torrents /data/media /opt/media-stack /opt/media-stack/config /opt/media-stack/stack; do
  mkdir -p "$d"
done
for t in movies tv anime music; do mkdir -p "/data/torrents/$t" "/data/media/$t"; done
chown 1000:1000 /data /data/torrents /data/media /data/torrents/* /data/media/* /opt/media-stack /opt/media-stack/config /opt/media-stack/stack
chmod 2775 /data /data/torrents /data/media /data/torrents/* /data/media/* /opt/media-stack/config /opt/media-stack/stack
chmod 0755 /opt/media-stack
echo 'BOOTSTRAP_OK'
EOF
  ;;
status)
  rs "qm status $VMID --verbose 2>&1 | grep -E '^(status|name|qmpstatus|uptime):' || echo 'VM $VMID: not found'
    qm agent $VMID ping >/dev/null 2>&1 && echo 'guest-agent: OK' || echo 'guest-agent: not answering'
    qm config $VMID 2>/dev/null | grep -E '^(scsi0|scsi1|ipconfig0):'"
  vssh 'docker info >/dev/null && test -d /data/media && echo VM_READY
    df -h /data | tail -1; findmnt -no SOURCE,FSTYPE /data
    stat -c "%A %u:%g %n" /data /data/torrents /data/media /data/torrents/* /data/media/* /opt/media-stack/config /opt/media-stack/stack' \
    || echo "FAIL: VM not ready over ssh ($VM_USER@$VM_IP)"
  ;;
*) sed -n '2,13p' "$0"; exit 1 ;;
esac
