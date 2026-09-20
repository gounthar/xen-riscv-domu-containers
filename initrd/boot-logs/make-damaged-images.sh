#!/bin/bash
# Build the three deliberately damaged images used to prove the truncation
# guard fires. Each one is a properly formed, complete cpio archive with
# something taken out of it, so the kernel unpacks it without complaining and
# only the manifest check can notice.
#
#   ./make-damaged-images.sh ../initrd-docker.cpio.gz /some/output/dir
set -euo pipefail
src=${1:?usage: make-damaged-images.sh <initrd.cpio.gz> <outdir>}
out=${2:?usage: make-damaged-images.sh <initrd.cpio.gz> <outdir>}
mkdir -p "$out"
cp "$src" "$out/src.cpio.gz"
docker run --rm --platform linux/amd64 -v "$(cd "$out" && pwd):/n" -w /n \
  xen-domu-initrd-tools:latest bash -c '
set -e
repack() {
  find . -mindepth 1 -printf "%P\n" | LC_ALL=C sort |
    cpio -o -H newc --reproducible --quiet | gzip -9 -n -c > "../$1"
}
unpack() { cd /n; rm -rf t; mkdir t; cd t; gzip -dc ../src.cpio.gz | cpio -idm --quiet; }
unpack
echo "neg-a victim: usr/share/terminfo/l/linux ($(stat -c %s usr/share/terminfo/l/linux) bytes)"
rm -f usr/share/terminfo/l/linux; repack neg-a-missing-file.cpio.gz
unpack; rm -f zz-payload-end; repack neg-b-no-sentinel.cpio.gz
unpack
echo "neg-c victim: usr/local/bin/docker ($(stat -c %s usr/local/bin/docker) bytes)"
rm -f usr/local/bin/docker; repack neg-c-no-docker-cli.cpio.gz
cd /n; rm -rf t; chown '"$(id -u):$(id -g)"' neg-*.cpio.gz'
ls -l "$out"/neg-*.cpio.gz
