#!/usr/bin/env bash
#
# Build the distro-root installer initrd: a Debian trixie riscv64 root with
# systemd and K3s, packed as a tarball inside a small busybox initramfs whose
# /init installs it onto the domU's PV disk and switches to it (see ./init).
#
# It answers one question the RAM payload cannot: what a kubelet reports as
# the node's identity when it runs under a real distro, where systemd, not our
# /init, creates /etc/machine-id on first boot.
#
#   ./build.sh                  # -> $OUT_DIR/initrd-distro.cpio.gz
#
# Environment:
#   WORK_DIR   scratch directory (default: $HOME/xen-domu-build/distro)
#   OUT_DIR    where the artifact lands (default: this script's directory)
#   K3S_BIN    the pinned k3s-riscv64 download from ../initrd/build.sh
#              (default: $HOME/xen-domu-build/initrd/dl/k3s-riscv64)
#
# Everything riscv64 runs in containers under qemu-user (binfmt_misc), so no
# sudo and no riscv64 host are needed, and it is slow.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK_DIR=${WORK_DIR:-$HOME/xen-domu-build/distro}
OUT_DIR=${OUT_DIR:-$SCRIPT_DIR}
K3S_BIN=${K3S_BIN:-$HOME/xen-domu-build/initrd/dl/k3s-riscv64}
# Same pin as ../initrd/build.sh (k3s-v1.37.0-k3s1-riscv64).
K3S_SHA256=09d54deb6941ebaa4daf7c573d095b2b711631836c2fc44ac9ddf0d00b4657e4
ROOT_IMAGE=xen-domu-distro-root:latest
TOOLS_IMAGE=xen-domu-initrd-tools:latest
export BUILDX_BUILDER=${BUILDX_BUILDER:-default}

for c in docker sha256sum; do
  command -v "$c" >/dev/null || {
    echo "Error: $c is required. On Debian: sudo apt-get install -y docker.io coreutils" >&2
    exit 1
  }
done
docker image inspect "$TOOLS_IMAGE" >/dev/null 2>&1 || {
  echo "Error: $TOOLS_IMAGE missing; run ../initrd/build.sh once, it builds it" >&2
  exit 1
}
[ -s "$K3S_BIN" ] || {
  echo "Error: $K3S_BIN missing; ../initrd/build.sh downloads it" >&2
  exit 1
}
echo "$K3S_SHA256  $K3S_BIN" | sha256sum -c -

BUILD_EPOCH=${SOURCE_DATE_EPOCH:-$(date +%s)}
ctx=$WORK_DIR/ctx
rm -rf "$ctx"
mkdir -p "$ctx"
install -m 0755 "$K3S_BIN" "$ctx/k3s-riscv64"
cp -a "$SCRIPT_DIR/overlay" "$ctx/overlay"

cat >"$ctx/Dockerfile" <<'EOF'
# Unpack the K3s bundle at the path it runs from, as ../initrd/build.sh does:
# its CNI symlinks are absolute.
FROM debian:trixie AS k3sdata
COPY k3s-riscv64 /tmp/k3s
RUN chmod 0755 /tmp/k3s && mkdir -p /var/lib/rancher/k3s && \
    (/tmp/k3s --data-dir /var/lib/rancher/k3s check-config >/dev/null 2>&1 || true) && \
    test -x /var/lib/rancher/k3s/data/current/bin/k3s && \
    cd /var/lib/rancher/k3s/data/current/bin && sha256sum -c --quiet .sha256sums && \
    rm -f /tmp/k3s /var/lib/rancher/k3s/data/.lock

FROM debian:trixie AS bb
RUN apt-get update && apt-get install -y --no-install-recommends busybox-static

# The root: what "apt install systemd" gives on a minimal Debian, plus the
# network and container plumbing K3s needs. No trimming, unlike the RAM
# payload: this goes on a disk, and it is meant to look like a distro.
FROM debian:trixie
ARG BUILD_EPOCH=0
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        systemd systemd-sysv systemd-resolved- udev dbus kmod iproute2 iptables \
        ca-certificates procps util-linux mount e2fsprogs && \
    (DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        systemd-networkd 2>/dev/null || test -x /usr/lib/systemd/systemd-networkd) && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
COPY --from=k3sdata /var/lib/rancher/k3s/data /var/lib/rancher/k3s/data
COPY overlay/ /
RUN ln -sf /var/lib/rancher/k3s/data/current/bin/k3s /usr/local/bin/k3s && \
    ln -sf /var/lib/rancher/k3s/data/current/bin/kubectl /usr/local/bin/kubectl && \
    mkdir -p /etc/rancher/k3s && \
    systemctl enable systemd-networkd.service systemd-networkd-wait-online.service \
        k3s.service identity-probe.service && \
    systemctl mask serial-getty@hvc0.service getty@tty1.service && \
    echo "$BUILD_EPOCH" > /etc/distro-build-epoch
COPY --from=bb /usr/bin/busybox /busybox-static
EOF

echo "=== building the riscv64 root image (emulated) ==="
t0=$(date +%s)
docker build --load --platform linux/riscv64 -t "$ROOT_IMAGE" \
  --build-arg "BUILD_EPOCH=$BUILD_EPOCH" "$ctx"
echo "root image build: $(($(date +%s) - t0))s wall"

cid=$(docker create --platform linux/riscv64 "$ROOT_IMAGE" /sbin/init)
docker export "$cid" >"$WORK_DIR/root-export.tar"
docker rm "$cid" >/dev/null
cp "$SCRIPT_DIR/init" "$WORK_DIR/init"

echo "=== assembling the installer initramfs ==="
docker run --rm --platform linux/amd64 -v "$WORK_DIR:/work" -w /work "$TOOLS_IMAGE" bash -c "
	set -e
	rm -rf root ir && mkdir root ir
	tar -xpf root-export.tar -C root
	mkdir -p ir/bin ir/dev ir/proc ir/sys ir/newroot
	mv root/busybox-static ir/bin/busybox && chmod 0755 ir/bin/busybox
	cp init ir/init && chmod 0755 ir/init
	mknod -m 600 ir/dev/console c 5 1
	mknod -m 666 ir/dev/null c 1 3

	cd root
	rm -f .dockerenv
	# docker export leaves these as empty bind-mount targets.
	echo domu > etc/hostname
	printf '127.0.0.1 localhost\n192.168.128.2 domu\n' > etc/hosts
	rm -f etc/resolv.conf
	echo 'nameserver 192.168.128.1' > etc/resolv.conf
	# First-boot state, as machine-id(5) describes for images: the file
	# exists and is empty, and D-Bus's copy is the symlink Debian ships, so
	# systemd has nothing baked in to reuse and must initialize it itself.
	: > etc/machine-id
	rm -f var/lib/dbus/machine-id
	ln -s /etc/machine-id var/lib/dbus/machine-id
	# systemd moves a clock older than this file's mtime forward to it at
	# boot; the domU has no RTC and starts in 1970, which K3s's
	# certificates would reject.
	touch -d @$BUILD_EPOCH usr/lib/clock-epoch
	echo \"machine-id bytes: \$(wc -c < etc/machine-id)\"
	ls -l var/lib/dbus/machine-id
	du -sm . | awk '{print \"root uncompressed MiB: \" \$1}'
	tar --numeric-owner -cpf - . | gzip -6 -n > ../ir/root.tar.gz
	cd ..
	ls -l ir/root.tar.gz
	(cd ir && find . -mindepth 1 | LC_ALL=C sort | cpio -o -H newc --reproducible --quiet) \
		> initrd-distro.cpio
	gzip -1 -n -c initrd-distro.cpio > initrd-distro.cpio.gz
	rm -rf root ir initrd-distro.cpio
	chown $(id -u):$(id -g) initrd-distro.cpio.gz
"
mkdir -p "$OUT_DIR"
cp "$WORK_DIR/initrd-distro.cpio.gz" "$OUT_DIR/"
(cd "$OUT_DIR" && sha256sum initrd-distro.cpio.gz | tee initrd-distro.cpio.gz.sha256)
ls -l "$OUT_DIR/initrd-distro.cpio.gz"
