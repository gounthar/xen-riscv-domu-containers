#!/usr/bin/env bash
#
# Build the riscv64 container test payload initrd (Docker + K3s, all in RAM).
#
# Everything that needs root or riscv64 execution happens inside containers, so
# this script needs no sudo. The riscv64 steps run under qemu-user emulation
# through binfmt_misc, which is why they are slow on an x86_64 host.
#
#   ./build.sh                     # docker, k3s and all (the default set)
#   VARIANT=docker ./build.sh      # just the docker-only image
#   VARIANT=all,full ./build.sh    # the combined image and the full one
#
# Four variants, because the RAM a domU needs is set by how much of the image
# the kernel has to unpack, not by what the test then uses:
#
#   docker  Docker engine plus the two test image tars  -> initrd-docker.cpio.gz
#   k3s     K3s tree plus the four airgap image tars    -> initrd-k3s.cpio.gz
#   all     both stacks, test=all runs them in turn     -> initrd.cpio.gz
#   full    all, plus traefik/servicelb/metrics-server  -> initrd-full.cpio.gz
#
# Environment:
#   WORK_DIR     scratch directory        (default: $HOME/xen-domu-build/initrd)
#   OUT_DIR      where the artifacts land (default: this script's directory)
#   VARIANT      comma-separated list     (default: docker,k3s,all)
#   STRIP        1 to strip the Go binaries, 0 to ship them as released (default 1)
#   SKIP_VERIFY  1 to accept checksums that do not match the pinned list
#   KEEP_IMAGES  1 to keep the images this build pulled into the host daemon
#   NO_CACHE     1 to rebuild the container images from scratch

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK_DIR=${WORK_DIR:-$HOME/xen-domu-build/initrd}
OUT_DIR=${OUT_DIR:-$SCRIPT_DIR}
VARIANT=${VARIANT:-docker,k3s,all}
STRIP=${STRIP:-1}
SKIP_VERIFY=${SKIP_VERIFY:-0}
KEEP_IMAGES=${KEEP_IMAGES:-0}
NO_CACHE=${NO_CACHE:-0}

# ------------------------------------------------------------------ sources --
REPO=gounthar/docker-for-riscv64
ENGINE_TAG=v29.8.0-riscv64  # engine, containerd, runc, shims, tini
CLI_TAG=cli-v29.8.0-riscv64 # docker CLI
K3S_TAG=k3s-v1.37.0-k3s1-riscv64
BASE_IMAGE=debian:trixie-slim

REL=https://github.com/$REPO/releases/download

# sha256 of every file this build downloads, measured 2026-09-19. A mismatch
# stops the build: swapping in a newer release means updating this list on
# purpose (run once with SKIP_VERIFY=1, then paste the new values here).
PINNED_SHA256=$(
  cat <<'EOF'
ab7cc56ee3799737bb43d4048b38a2bd41acd539620542920ff23af40d0884f3  dockerd
fbb87aa7a4df947ae145413e0d4ef6ac35bb612652bc11ca38522a968a3e01b1  containerd
bb5f428d32521aadb1b288dd104f16ffc71d962f712534873ef880380d551731  containerd-shim-runc-v2
19a367d250a539b5543193b60969c29ca4c014063eb9ace9025fabe2127d54e8  runc
994e8d6a9aa980004fa6cca200a501500072967f96367e05f7bf49af34fc51b7  docker
09d54deb6941ebaa4daf7c573d095b2b711631836c2fc44ac9ddf0d00b4657e4  k3s-riscv64
EOF
)

# Images K3s pulls, from the k3s-images-riscv64.txt release asset. The minimal
# set is what "--disable traefik,servicelb,metrics-server" actually needs, plus
# the two images the tests themselves run: hello-world is what both the Docker
# run and the K3s pod execute, and busybox is kept because hello-world exits
# immediately and carries no shell, so the seccomp check needs something that
# can read /proc/self/status.
MIN_IMAGES=(
  "docker.io/carvicsforth/pause:3.10.2"
  "docker.io/rancher/mirrored-coredns-coredns:1.14.7"
  "docker.io/rancher/local-path-provisioner:v0.0.37"
  "docker.io/busybox:1.37.0"
  "docker.io/hello-world:latest"
)
FULL_EXTRA_IMAGES=(
  "docker.io/rancher/klipper-helm:v0.13.3-build20260727"
  "docker.io/carvicsforth/klipper-lb:v0.4.17"
  "docker.io/rancher/mirrored-library-traefik:3.7.13"
  "docker.io/carvicsforth/metrics-server:v0.9.0"
)

TOOLS_IMAGE=xen-domu-initrd-tools:latest
ROOTFS_IMAGE=xen-domu-initrd-rootfs:latest

# Both builds use --load and then talk to the host daemon's image store, so
# they want the plain docker driver. A docker-container buildx builder left
# selected in the environment fails here with an "invalid mount config for
# type bind" error on the build context, which does not name buildx anywhere.
export BUILDX_BUILDER=${BUILDX_BUILDER:-default}

# ------------------------------------------------------------ dependencies --
check_deps() {
  local missing=()
  local c
  for c in docker curl sha256sum awk sed tar; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Error: missing required commands: ${missing[*]}" >&2
    echo "On Debian/Ubuntu: sudo apt-get install -y docker.io curl coreutils mawk sed tar" >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "Error: cannot talk to the Docker daemon." >&2
    echo "On Debian/Ubuntu: sudo apt-get install -y docker.io && sudo usermod -aG docker \$USER" >&2
    exit 1
  fi
  if ! docker run --rm --platform linux/riscv64 "$BASE_IMAGE" true >/dev/null 2>&1; then
    echo "Error: this host cannot run linux/riscv64 containers." >&2
    echo "Install binfmt handlers first:" >&2
    echo "  docker run --privileged --rm tonistiigi/binfmt --install riscv64" >&2
    exit 1
  fi
  command -v skopeo >/dev/null 2>&1 ||
    echo "Note: skopeo is not installed; the image tar check will be skipped." >&2
}

# ------------------------------------------------------------------ timing --
TIMING_LOG=""
step_start=0
step() {
  step_start=$(date +%s)
  echo
  echo "=== $* ==="
}
step_end() {
  local end=$(($(date +%s) - step_start))
  printf '%-52s wall %4ds\n' "$1" "$end" >>"$TIMING_LOG"
  echo "--- $1: ${end}s"
}

verify_downloads() {
  echo "verifying downloads against the pinned checksums:"
  if printf '%s\n' "$PINNED_SHA256" | (cd "$WORK_DIR/dl" && sha256sum -c -); then
    return 0
  fi
  echo "Error: a downloaded file does not match its pinned sha256." >&2
  [ "$SKIP_VERIFY" = 1 ] || exit 1
}

# ------------------------------------------------------------------- fetch --
fetch() {
  local url=$1 dest=$2
  [ -s "$dest" ] && return 0
  echo "  fetching $(basename "$dest")"
  curl -fsSL --retry 3 -o "$dest.part" "$url"
  mv "$dest.part" "$dest"
}

do_fetch() {
  mkdir -p "$WORK_DIR/dl"
  local f
  for f in dockerd containerd containerd-shim-runc-v2 runc \
    VERSIONS.txt; do
    fetch "$REL/$ENGINE_TAG/$f" "$WORK_DIR/dl/$f"
  done
  fetch "$REL/$CLI_TAG/docker" "$WORK_DIR/dl/docker"
  for f in k3s-riscv64 k3s-riscv64.sha256sum k3s-images-riscv64.txt; do
    fetch "$REL/$K3S_TAG/$f" "$WORK_DIR/dl/$f"
  done

  verify_downloads
  # The K3s release ships its own checksum; use it as well as the pin.
  (cd "$WORK_DIR/dl" && sha256sum -c k3s-riscv64.sha256sum)
}

# ---------------------------------------------------- tools container image --
build_tools_image() {
  local ctx=$WORK_DIR/tools
  mkdir -p "$ctx"
  cat >"$ctx/Dockerfile" <<-'EOF'
		FROM debian:trixie
		RUN apt-get update && \
		    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		        binutils-riscv64-linux-gnu cpio gzip zstd rpm2cpio file ca-certificates && \
		    rm -rf /var/lib/apt/lists/*
	EOF
  docker build --load --platform linux/amd64 -q -t "$TOOLS_IMAGE" "$ctx" >/dev/null
}

in_tools() {
  docker run --rm --platform linux/amd64 \
    -v "$WORK_DIR:/work" -w /work "$TOOLS_IMAGE" bash -c "$1"
}

# ---------------------------------------------------- binaries: strip only --
# docker-proxy and tini (docker-init) are deliberately not shipped: the tests
# run with --network none and never pass --init, so neither is reachable.
# dockerd is started with --userland-proxy=false to match.
prepare_binaries() {
  rm -rf "$WORK_DIR/ctx/bin"
  mkdir -p "$WORK_DIR/ctx/bin"
  in_tools "
		set -e
		cd /work
		for f in dockerd containerd containerd-shim-runc-v2 runc docker; do
		  cp dl/\$f ctx/bin/\$f
		  if [ '$STRIP' = 1 ]; then riscv64-linux-gnu-strip ctx/bin/\$f 2>/dev/null || true; fi
		  chmod 0755 ctx/bin/\$f
		done
		chown -R $(id -u):$(id -g) /work/ctx
		cd /work/ctx/bin && sha256sum * > /work/ctx-bin.sha256
	"
  echo "binaries in the image:"
  ls -l "$WORK_DIR/ctx/bin"
}

# ---------------------------------------------------------------- image set --
save_images() {
  local variant=$1
  shift
  local dir=$WORK_DIR/images/$variant
  mkdir -p "$dir"
  local ref name tag out
  for ref in "$@"; do
    name=${ref##*/}
    tag=${name##*:}
    name=${name%%:*}
    out=$dir/$name-$tag.tar
    [ -s "$out" ] && continue
    if ! docker image inspect "$ref" >/dev/null 2>&1; then
      echo "$ref" >>"$WORK_DIR/pulled-refs.txt"
    fi
    echo "  pulling $ref"
    docker pull -q --platform linux/riscv64 "$ref" >/dev/null
    docker save --platform linux/riscv64 -o "$out" "$ref"
    echo "  saved $(basename "$out") ($(du -h "$out" | cut -f1))"
  done
}

drop_pulled_images() {
  [ "$KEEP_IMAGES" = 1 ] && return 0
  [ -s "$WORK_DIR/pulled-refs.txt" ] || return 0
  local ref
  while read -r ref; do
    docker rmi "$ref" >/dev/null 2>&1 || true
  done <"$WORK_DIR/pulled-refs.txt"
  rm -f "$WORK_DIR/pulled-refs.txt"
}

# ------------------------------------------------------------- rootfs image --
build_rootfs_image() {
  local ctx=$WORK_DIR/ctx
  mkdir -p "$ctx"
  cp "$SCRIPT_DIR/init" "$ctx/init"
  install -m 0755 "$WORK_DIR/dl/k3s-riscv64" "$ctx/k3s-riscv64"
  cat >"$ctx/Dockerfile" <<-EOF
		# syntax=docker/dockerfile:1
		# Stage 1: unpack the K3s self-extracting bundle at the path it will run
		# from. The CNI symlinks it writes are absolute, so the data dir has to be
		# unpacked at its final location, not moved there afterwards.
		FROM $BASE_IMAGE AS k3sdata
		COPY k3s-riscv64 /tmp/k3s
		RUN chmod 0755 /tmp/k3s && mkdir -p /var/lib/rancher/k3s && \\
		    (/tmp/k3s --data-dir /var/lib/rancher/k3s check-config >/dev/null 2>&1 || true) && \\
		    test -x /var/lib/rancher/k3s/data/current/bin/k3s && \\
		    cd /var/lib/rancher/k3s/data/current/bin && sha256sum -c --quiet .sha256sums && \\
		    rm -f /tmp/k3s /var/lib/rancher/k3s/data/.lock

		FROM $BASE_IMAGE
		ARG BUILD_EPOCH=0
		RUN apt-get update && \\
		    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
		        bash busybox ca-certificates iproute2 iptables mawk mount procps util-linux && \\
		    apt-get clean && \\
		    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/cache/debconf/*-old \\
		           /usr/share/doc /usr/share/man /usr/share/info /usr/share/locale \\
		           /usr/share/lintian /usr/share/bug /var/lib/dpkg/info/*.md5sums \\
		           /usr/lib/riscv64-linux-gnu/gconv

		# Nothing in the payload runs apt, dpkg or perl, and every megabyte cut
		# here lowers the RAM floor by about two: the image has to fit inside a
		# tmpfs capped at half of guest RAM. Measured saving: see NOTES.md.
		RUN set -e; \\
		    rm -rf /usr/bin/perl /usr/bin/perl5.* /usr/lib/riscv64-linux-gnu/perl-base \\
		           /usr/share/perl /usr/share/perl5 \\
		           /usr/bin/apt /usr/bin/apt-* /usr/lib/apt /var/lib/apt /etc/apt \\
		           /usr/lib/riscv64-linux-gnu/libapt-pkg.so* \\
		           /usr/lib/riscv64-linux-gnu/libapt-private.so* \\
		           /usr/lib/riscv64-linux-gnu/libstdc++.so* \\
		           /usr/bin/dpkg /usr/bin/dpkg-* /usr/sbin/dpkg-* /usr/share/dpkg \\
		           /var/lib/dpkg /etc/dpkg /usr/bin/sqv \\
		           /usr/share/common-licenses /usr/share/bash-completion \\
		           /usr/share/keyrings /usr/share/gcc /usr/share/base-files \\
		           /usr/share/pixmaps /usr/share/polkit-1 /usr/share/zsh \\
		           /usr/share/menu /usr/share/debconf /var/cache/debconf \\
		           /usr/share/ca-certificates /usr/lib/systemd /usr/lib/tmpfiles.d \\
		           /var/lib/systemd; \\
		    find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 \\
		         ! -name UTC ! -name Etc -exec rm -rf {} +; \\
		    find /usr/share/zoneinfo/Etc -mindepth 1 ! -name UTC -delete; \\
		    find /etc/ssl/certs -xtype l -delete; \\
		    test -s /etc/ssl/certs/ca-certificates.crt
		COPY bin/ /usr/local/bin/
		COPY --from=k3sdata /var/lib/rancher/k3s/data /var/lib/rancher/k3s/data
		COPY init /init
		RUN mkdir -p /var/lib/rancher/k3s/agent/images /etc/rancher/k3s /var/lib/docker \\
		             /var/lib/containerd /var/log /newroot /root && \\
		    chmod 0755 /init && \\
		    echo "\$BUILD_EPOCH" > /etc/payload-build-epoch && \\
		    ln -sf /var/lib/rancher/k3s/data/current/bin/k3s /usr/local/bin/k3s && \\
		    ln -sf /var/lib/rancher/k3s/data/current/bin/kubectl /usr/local/bin/kubectl
	EOF
  local args=(--load --platform linux/riscv64 -t "$ROOTFS_IMAGE"
    --build-arg "BUILD_EPOCH=$BUILD_EPOCH" -f "$ctx/Dockerfile" "$ctx")
  [ "$NO_CACHE" = 1 ] && args=(--no-cache "${args[@]}")
  docker build "${args[@]}"
}

# ------------------------------------------------------------ offline check --
offline_checks() {
  bash -n "$SCRIPT_DIR/init"
  echo "  init: bash -n ok"
  docker run --rm --platform linux/riscv64 "$ROOTFS_IMAGE" bash -c '
		set -e
		echo "  uname: $(uname -m)"
		for c in bash tar cp switch_root mountpoint setsid dmesg ip iptables \
		         free sysctl busybox awk df date timeout find sha256sum stat \
		         sed grep du rm mkdir sleep dd od head blockdev mount umount \
		         readlink basename; do
		  command -v $c >/dev/null || { echo "  MISSING: $c"; exit 1; }
		done
		# Run them, not just find them: the base trim removes shared libraries,
		# and a binary whose loader cannot resolve a NEEDED entry is still on
		# PATH. --help is enough to reach the dynamic loader.
		for c in bash tar cp mountpoint setsid dmesg free sysctl awk df \
		         date find sha256sum stat sed grep du dd od head blockdev \
		         umount readlink basename; do
		  $c --help >/dev/null 2>&1 || $c --version >/dev/null 2>&1 || \
		    { echo "  BROKEN (will not run): $c"; exit 1; }
		done
		# iproute2 takes -V, not --version, and answers -help with status 255.
		ip link show lo >/dev/null 2>&1 || { echo "  BROKEN: ip"; exit 1; }
		switch_root --help 2>&1 | grep -qi usage || { echo "  BROKEN: switch_root"; exit 1; }
		busybox poweroff --help >/dev/null 2>&1 || busybox | head -1 >/dev/null
		# The disk test makes its filesystem with busybox, not e2fsprogs,
		# which is not in the image. A missing applet would only show up at
		# boot, on a guest that has a disk, as a DISK_FAIL.
		for a in mke2fs mkdosfs; do
		  busybox --list | grep -qx "$a" || { echo "  busybox has no $a applet"; exit 1; }
		done
		echo "  busybox provides mke2fs and mkdosfs for the disk test"
		# iptables cannot initialize nft inside the build container, so only the
		# dynamic loader is checked here. The payload exercises it for real.
		case "$(iptables --version 2>&1)" in
		*"error while loading"* | *"No such file or directory"*)
		  echo "  BROKEN: iptables"; exit 1 ;;
		esac
		echo "  all required userland commands present and runnable"
		test ! -e /usr/bin/docker-proxy -a ! -e /usr/local/bin/docker-proxy
		test ! -e /usr/local/bin/docker-init
		echo "  docker-proxy and docker-init are absent, as intended"
		runc --version | tr "\n" " "; echo
		runc --version | grep -q "^libseccomp:" || { echo "  runc has NO libseccomp"; exit 1; }
		dockerd --version; docker --version; containerd --version
		/var/lib/rancher/k3s/data/current/bin/k3s --version | head -1
		/var/lib/rancher/k3s/data/current/bin/kubectl version --client | head -1
		test -x /init && bash -n /init && echo "  /init present and parses"
	'
  local t
  if command -v skopeo >/dev/null 2>&1; then
    for t in "$WORK_DIR/images/$1"/*.tar; do
      printf '  %s: ' "$(basename "$t")"
      skopeo inspect "docker-archive:$t" |
        awk -F'"' '/"Architecture"|"Os"/ {printf "%s ", $4} END {print ""}'
    done
  fi
}

# ---------------------------------------------------------------- assemble --
# Which image tars each variant carries, and what it drops from the rootfs.
variant_out() {
	case "$1" in
	docker) echo initrd-docker.cpio.gz ;;
	k3s) echo initrd-k3s.cpio.gz ;;
	all) echo initrd.cpio.gz ;;
	full) echo initrd-full.cpio.gz ;;
	esac
}

variant_images_dir() {
	case "$1" in
	full) echo full ;;
	*) echo minimal ;;
	esac
}

# Files named in the manifest and checked by /init before any test runs. The
# file list and byte total already cover them; these give the failure a name
# instead of only a count, and they cost a stat each.
variant_critical() {
	local common="init usr/bin/bash usr/bin/tar usr/sbin/switch_root
		usr/bin/busybox usr/bin/find usr/bin/sha256sum usr/bin/df
		usr/bin/stat usr/bin/awk etc/payload-build-epoch"
	local docker="usr/local/bin/dockerd usr/local/bin/containerd
		usr/local/bin/containerd-shim-runc-v2 usr/local/bin/runc
		usr/local/bin/docker
		var/lib/rancher/k3s/agent/images/busybox-1.37.0.tar
		var/lib/rancher/k3s/agent/images/hello-world-latest.tar"
	local k3s="var/lib/rancher/k3s/data/current/bin/k3s
		var/lib/rancher/k3s/data/current/bin/containerd-shim-runc-v2
		var/lib/rancher/k3s/data/current/bin/runc
		var/lib/rancher/k3s/data/current/bin/cni
		var/lib/rancher/k3s/data/current/bin/aux/xtables-nft-multi
		var/lib/rancher/k3s/agent/images/pause-3.10.2.tar
		var/lib/rancher/k3s/agent/images/mirrored-coredns-coredns-1.14.7.tar
		var/lib/rancher/k3s/agent/images/local-path-provisioner-v0.0.37.tar
		var/lib/rancher/k3s/agent/images/busybox-1.37.0.tar
		var/lib/rancher/k3s/agent/images/hello-world-latest.tar"
	echo "$common"
	case "$1" in
	docker) echo "$docker" ;;
	k3s) echo "$k3s" ;;
	*) echo "$docker"; echo "$k3s" ;;
	esac
}

assemble() {
	local variant=$1
	local out=$OUT_DIR/$(variant_out "$variant")
	local imgsrc imgfilter prune crit cid
	imgsrc=$(variant_images_dir "$variant")
	case "$variant" in
	docker)
		imgfilter='{busybox-1.37.0,hello-world-latest}.tar'
		prune='rm -rf var/lib/rancher/k3s/data usr/local/bin/k3s usr/local/bin/kubectl'
		;;
	k3s)
		imgfilter='*.tar'
		prune='rm -f usr/local/bin/dockerd usr/local/bin/containerd usr/local/bin/containerd-shim-runc-v2 usr/local/bin/runc usr/local/bin/docker; rm -rf var/lib/docker var/lib/containerd'
		;;
	*)
		imgfilter='*.tar'
		prune=':'
		;;
	esac
	crit=$(variant_critical "$variant" | tr -s ' \n' ' ')

	cid=$(docker create --platform linux/riscv64 "$ROOTFS_IMAGE" /init)
	docker export "$cid" >"$WORK_DIR/rootfs.tar"
	docker rm "$cid" >/dev/null

	in_tools "
		set -e
		cd /work
		rm -rf stage && mkdir stage
		tar -xpf rootfs.tar -C stage
		cd stage
		rm -f .dockerenv
		rm -rf proc sys dev run tmp newroot
		mkdir -p proc sys dev run tmp newroot var/lib/rancher/k3s/agent/images
		chmod 1777 tmp
		# The kernel opens /dev/console before running /init, and devtmpfs is
		# not mounted yet at that point, so these have to be in the archive.
		mknod -m 600 dev/console c 5 1
		mknod -m 666 dev/null c 1 3
		mknod -m 666 dev/zero c 1 5
		mknod -m 666 dev/tty c 5 0
		mknod -m 444 dev/random c 1 8
		mknod -m 444 dev/urandom c 1 9
		: > etc/hostname; : > etc/hosts; : > etc/resolv.conf
		$prune
		cp /work/images/$imgsrc/$imgfilter var/lib/rancher/k3s/agent/images/

		# The sentinel sorts last under LC_ALL=C, so the kernel writes it last:
		# if it is present and intact, the unpack reached the end of the stream.
		printf 'payload-end %s %s\n' '$variant' '$BUILD_EPOCH' > zz-payload-end
		{
		  echo '# riscv64 container test payload: build-time manifest'
		  echo '# /init checks this before running any test. See NOTES.md.'
		  echo 'variant=$variant'
		  echo 'build_epoch=$BUILD_EPOCH'
		  # data/current is an absolute symlink, which resolves at boot but not
		  # in the staging directory, so stat goes through the hashed name.
		  k3sdir=\$(basename \"\$(readlink var/lib/rancher/k3s/data/current 2>/dev/null)\" 2>/dev/null)
		  for f in $crit; do
		    sp=\$f
		    case \"\$f\" in
		    var/lib/rancher/k3s/data/current/*)
		      sp=var/lib/rancher/k3s/data/\$k3sdir/\${f#var/lib/rancher/k3s/data/current/} ;;
		    esac
		    if [ -e \"\$sp\" ]; then
		      printf 'critical=%s:%s\n' \"\$f\" \"\$(stat -c %s \"\$sp\")\"
		    else
		      echo \"manifest: missing critical file \$f (looked at \$sp)\" >&2; exit 1
		    fi
		  done
		  echo 'sentinel=zz-payload-end'
		  printf 'sentinel_sha256=%s\n' \"\$(sha256sum zz-payload-end | cut -d' ' -f1)\"
		} > etc/payload-manifest
		# Counted with the same rule /init uses: everything but the
		# pseudo-filesystems and the manifest file itself, which is why the
		# two lines below can be appended without changing the answer.
		find . -mindepth 1 \\( -path ./proc -o -path ./sys -o -path ./dev \\
		  -o -path ./run -o -path ./tmp -o -path ./newroot \\
		  -o -path ./etc/payload-manifest \\) -prune -o -printf '%y %s\n' |
		  awk '{n++; if (\$1==\"f\") b+=\$2} END {printf \"files=%d\nbytes=%d\n\", n, b}' \\
		  >> etc/payload-manifest
		cat etc/payload-manifest | grep -v '^critical=' > /work/manifest-$variant.txt

		du -sb . | awk '{printf \"uncompressed bytes: %s\n\", \$1}' > /work/size-$variant.txt
		find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort |
		  cpio -o -H newc --reproducible --quiet > /work/initrd-$variant.cpio
		gzip -9 -n -c /work/initrd-$variant.cpio > /work/initrd-$variant.cpio.gz
		zstd -19 -q -f -o /work/initrd-$variant.cpio.zst /work/initrd-$variant.cpio
		cd /work
		stat -c '%n %s' initrd-$variant.cpio initrd-$variant.cpio.gz initrd-$variant.cpio.zst \\
		  >> size-$variant.txt
		sha256sum initrd-$variant.cpio.gz >> size-$variant.txt
		chown $(id -u):$(id -g) initrd-$variant.cpio.gz initrd-$variant.cpio.zst \\
		  size-$variant.txt manifest-$variant.txt
		rm -rf stage initrd-$variant.cpio
	"
	mkdir -p "$OUT_DIR"
	cp "$WORK_DIR/initrd-$variant.cpio.gz" "$out"
	# zstd is smaller but the kernel only guarantees RD_GZIP; ship both and let
	# the tester pick (the part A kernel does have CONFIG_RD_ZSTD=y).
	cp "$WORK_DIR/initrd-$variant.cpio.zst" "${out%.gz}.zst"
	sha256sum "$out" | awk '{print $1"  "FILENAME}' FILENAME="$(basename "$out")" >"$out.sha256"
	cat "$WORK_DIR/size-$variant.txt"
	cat "$WORK_DIR/manifest-$variant.txt"
	echo "  artifact: $out"
}

# -------------------------------------------------------------------- main --
main() {
  check_deps
  mkdir -p "$WORK_DIR"
  TIMING_LOG=$WORK_DIR/build-timings.log
  : >"$TIMING_LOG"
  BUILD_EPOCH=${SOURCE_DATE_EPOCH:-$(date +%s)}
  echo "work dir:  $WORK_DIR"
  echo "out dir:   $OUT_DIR"
  echo "variant:   $VARIANT"
  echo "strip:     $STRIP"

  step "downloading release assets"
  do_fetch
  step_end "download release assets"

  step "building the amd64 tools image"
  build_tools_image
  step_end "build tools image"

  step "preparing binaries (strip=$STRIP)"
  prepare_binaries
  step_end "prepare binaries"

  local variants=() v
  IFS=',' read -r -a variants <<<"$VARIANT"
  for v in "${variants[@]}"; do
    case "$v" in
    docker | k3s | all | full) ;;
    minimal)
      echo "Note: VARIANT=minimal is now called 'all'." >&2
      exit 1
      ;;
    *)
      echo "Error: unknown variant '$v'; use docker, k3s, all or full" >&2
      exit 1
      ;;
    esac
  done

  step "pulling and saving riscv64 images"
  save_images minimal "${MIN_IMAGES[@]}"
  if [[ " ${variants[*]} " == *" full "* ]]; then
    mkdir -p "$WORK_DIR/images/full"
    cp -n "$WORK_DIR/images/minimal"/*.tar "$WORK_DIR/images/full/"
    save_images full "${FULL_EXTRA_IMAGES[@]}"
  fi
  step_end "pull and save images"

  step "building the riscv64 rootfs image (apt + K3s unpack, emulated)"
  build_rootfs_image
  step_end "build rootfs image"

  step "offline checks inside a riscv64 container"
  offline_checks minimal
  step_end "offline checks"

  for v in "${variants[@]}"; do
    step "assembling the $v initrd"
    assemble "$v"
    step_end "assemble $v initrd"
  done

  drop_pulled_images

  echo
  echo "=== timings (wall clock; riscv64 steps run under qemu-user) ==="
  cat "$TIMING_LOG"
  echo
  ls -l "$OUT_DIR"/initrd*.cpio.gz
}

main "$@"
