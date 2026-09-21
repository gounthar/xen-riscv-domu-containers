#!/bin/bash
# run-boot.sh <tag> <mem-mb> <initrd-file> <append-extra...>
set -u
BOOTDIR=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$BOOTDIR/logs}
SMP=${SMP:-4}
HARDTIMEOUT=${HARDTIMEOUT:-3000}
tag=$1; mem=$2; INITRD=$3; shift 3
extra="$*"
mkdir -p "$OUT"
log="$OUT/$tag.log"; meta="$OUT/$tag.meta"
append="console=ttyS0 $extra"
{
  echo "tag:      $tag"
  echo "qemu:     10.0.13 (container xen-domu-qemu:latest, Debian trixie)"
  echo "kernel:   Image  sha256 $(sha256sum "$BOOTDIR/Image" | cut -d' ' -f1)"
  echo "initrd:   $INITRD  sha256 $(sha256sum "$BOOTDIR/$INITRD" | cut -d' ' -f1)"
  echo "machine:  -M virt -m $mem -smp $SMP -nographic -no-reboot -nic none"
  echo "append:   $append"
  echo "started:  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >"$meta"
start=$(date +%s)
timeout --foreground "$HARDTIMEOUT" \
  docker run --rm -i --name "boot-$tag" \
  -v "$BOOTDIR:/work:ro" xen-domu-qemu:latest \
  qemu-system-riscv64 -M virt -m "$mem" -smp "$SMP" -nographic -no-reboot \
  -nic none -kernel /work/Image -initrd "/work/$INITRD" \
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
