#!/bin/bash
# run-boot-dev.sh <tag> <mem-mb> <initrd-file> <append-extra...>
#
# Same as run-boot.sh, but gives the guest a block device and, optionally, a
# network interface, so the payload's disk test and its real-interface path can
# be exercised on plain QEMU. The payload kernel has no Xen frontends, so the
# stand-ins are virtio-blk (/dev/vda) and virtio-net (eth0); what they exercise
# is the payload's code, not blkfront or netfront.
#
#   DISK_MB=64   size of the scratch image, recreated on every run
#   WITH_NIC=1   attach an isolated virtio-net device (restrict=y: no uplink,
#                no DHCP reachable, which is the first domU milestone's shape)
#   WITH_DISK=0  leave the disk off
#   DISK_RO=1    present the disk read-only, so the payload's raw write fails
set -u
BOOTDIR=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$BOOTDIR/logs}
SMP=${SMP:-4}
HARDTIMEOUT=${HARDTIMEOUT:-3000}
DISK_MB=${DISK_MB:-64}
WITH_NIC=${WITH_NIC:-0}
WITH_DISK=${WITH_DISK:-1}
DISK_RO=${DISK_RO:-0}
tag=$1; mem=$2; INITRD=$3; shift 3
extra="$*"
mkdir -p "$OUT" "$BOOTDIR/scratch"
log="$OUT/$tag.log"; meta="$OUT/$tag.meta"
append="console=ttyS0 $extra"

dev_args=()
ro=""
disk="$BOOTDIR/scratch/$tag.img"
if [ "$WITH_DISK" = 1 ]; then
  rm -f "$disk"
  dd if=/dev/zero of="$disk" bs=1M count="$DISK_MB" status=none
  [ "$DISK_RO" = 1 ] && ro=",readonly=on"
  dev_args+=(-drive "file=/work/scratch/$tag.img,if=none,id=d0,format=raw$ro"
    -device virtio-blk-device,drive=d0)
fi
if [ "$WITH_NIC" = 1 ]; then
  dev_args+=(-netdev user,id=n0,restrict=y -device virtio-net-device,netdev=n0)
else
  dev_args+=(-nic none)
fi

{
  echo "tag:      $tag"
  echo "qemu:     10.0.13 (container xen-domu-qemu:latest, Debian trixie)"
  echo "kernel:   Image  sha256 $(sha256sum "$BOOTDIR/Image" | cut -d' ' -f1)"
  echo "initrd:   $INITRD  sha256 $(sha256sum "$BOOTDIR/$INITRD" | cut -d' ' -f1)"
  echo "machine:  -M virt -m $mem -smp $SMP -nographic -no-reboot ${dev_args[*]}"
  if [ "$WITH_DISK" = 1 ]; then
    echo "disk:     $DISK_MB MiB raw virtio-blk, zeroed before the run${ro:+, READ-ONLY}"
  else
    echo "disk:     none"
  fi
  if [ "$WITH_NIC" = 1 ]; then
    echo "nic:      virtio-net, user mode, restrict=y (isolated: no uplink, no DHCP)"
  else
    echo "nic:      none (-nic none)"
  fi
  echo "append:   $append"
  echo "started:  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >"$meta"

start=$(date +%s)
timeout --foreground "$HARDTIMEOUT" \
  docker run --rm -i --name "boot-$tag" \
  -v "$BOOTDIR:/work" xen-domu-qemu:latest \
  qemu-system-riscv64 -M virt -m "$mem" -smp "$SMP" -nographic -no-reboot \
  "${dev_args[@]}" -kernel /work/Image -initrd "/work/$INITRD" \
  -append "$append" \
  </dev/null >"$log" 2>&1
rc=$?
end=$(date +%s)
{
  echo "finished: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "exit:     $rc"
  echo "wall_s:   $((end - start))"
} >>"$meta"
echo "$tag: exit=$rc wall=$((end - start))s"
exit $rc
