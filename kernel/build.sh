#!/bin/bash
# Build a riscv64 test kernel from defconfig + container.config.
#
# Runs on the host and does the actual work inside a debian:trixie amd64
# container (kbuild-riscv:trixie, see builder/Dockerfile in NOTES.md), so
# nothing needs installing on the host beyond Docker.
#
# Usage: build.sh [WORKDIR]
#   WORKDIR defaults to ~/xen-domu-build/kernel and must contain the
#   extracted linux-$KVER tree. Build on a native Linux filesystem, not /mnt/c.

set -euo pipefail

if ! command -v docker &>/dev/null; then
  echo "Error: docker is required but not installed." >&2
  exit 1
fi

KVER="${KVER:-7.2.6}"
WORKDIR="${1:-$HOME/xen-domu-build/kernel}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$WORKDIR/linux-$KVER"
JOBS="${JOBS:-$(nproc)}"
IMAGE="${IMAGE:-kbuild-riscv:trixie}"
LOG="$WORKDIR/build-$KVER.log"

[ -d "$SRC" ] || {
  echo "Error: $SRC not found" >&2
  exit 1
}
cp "$HERE/container.config" "$WORKDIR/container.config"

run() {
  docker run --rm -u "$(id -u):$(id -g)" -v "$WORKDIR:/work" -w "/work/linux-$KVER" \
    -e ARCH=riscv -e CROSS_COMPILE=riscv64-linux-gnu- "$IMAGE" bash -c "$1"
}

{
  echo "== $(date -Is) build of linux-$KVER, ARCH=riscv, cross on $(uname -m), $JOBS jobs"
  echo "== step 1: defconfig + merge fragment + olddefconfig"
  time run "make -s mrproper && scripts/kconfig/merge_config.sh -m arch/riscv/configs/defconfig /work/container.config && make olddefconfig"
  echo "== step 2: Image + Image.gz"
  time run "make -j$JOBS Image Image.gz"
  echo "== step 3: copy artifacts next to this script"
  cp "$SRC/arch/riscv/boot/Image" "$SRC/arch/riscv/boot/Image.gz" "$HERE/"
  cp "$SRC/.config" "$HERE/config-$KVER"
  ls -l "$HERE/Image" "$HERE/Image.gz" "$HERE/config-$KVER"
} 2>&1 | tee "$LOG"
