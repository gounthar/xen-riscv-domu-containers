# riscv64 container kernel: build notes

Part A of the test payload: a Kconfig fragment for running Docker and K3s, plus a
test kernel built with it. The eventual target is a Xen dom0less domU on RISC-V,
but everything here was only tested on plain `qemu-system-riscv64 -M virt` with no
Xen involved.

## What is in this directory

| File | What it is |
| --- | --- |
| `container.config` | The Kconfig fragment. Mergeable with `scripts/kconfig/merge_config.sh`, all `=y`, commented by group. |
| `Image`, `Image.gz` | The test kernel, Linux 7.2.6, ARCH=riscv. 29 MB and 10 MB. |
| `config-7.2.6` | The full `.config` those were built from. |
| `fragment-check.txt` | Every fragment symbol checked against the final `.config`. 141/141, nothing dropped. |
| `check-config-moby.txt` | moby `contrib/check-config.sh` run against `config-7.2.6`, with the caveats written out. |
| `check-config-k3s.txt` | `k3s check-config` run against `config-7.2.6`. STATUS: pass. |
| `qemu-smoke-test.txt` | A boot on `-M virt` without an initrd, to prove the Image boots and `console=ttyS0` works. |
| `check-fragment.py` | The checker that produced `fragment-check.txt`. |
| `build.sh`, `Dockerfile.builder` | The build, so it can be repeated. |

## Kernel version, and why

**Linux 7.2.6**, released 2026-09-14, the latest stable on
<https://www.kernel.org/releases.json> at the time of the build (2026-09-19). The
mainline entry is 7.3-rc3, an -rc, so it was skipped as the brief says. No reason
to fall back to a longterm: 7.2.6 is a current stable point release, and picking
the newest stable means the fragment is checked against the netfilter Kconfig
layout we will actually meet in future work rather than an older one.

Source verified against the `sha256sums.asc` published next to it on
cdn.kernel.org:
`039aef84f2b0994aeda3f4fcfc3d02ec9d7a9bbb9020ea264c43f446c860f606`. The PGP
signature on that sums file was **not** checked, only the hash it contains.

## Build environment

**Cross build on x86_64**, WSL2 Debian, 20 cores, 31 GB RAM, inside a
`debian:trixie` amd64 container. Not native riscv64, and the difference is large
enough to matter if these numbers are ever compared to a board build.

The host has `riscv64-linux-gnu-gcc` 14.2 but not `flex`, `bison` or
`qemu-system-riscv64`, and installing them needs a password, hence the container.
The toolchain inside the container is `riscv64-linux-gnu-gcc (Debian 14.2.0-19)
14.2.0` with binutils 2.44.

The source tree lives on the WSL ext4 root (`~/xen-domu-build/kernel`), not under
`/mnt/c`. Building over the 9p mount is slow enough to be worth avoiding, and
`/tmp` is a 5 GB tmpfs, too small.

## Build commands

Builder image:

```bash
mkdir -p ~/xen-domu-build/kernel/builder
cp Dockerfile.builder ~/xen-domu-build/kernel/builder/Dockerfile
docker build --load -t kbuild-riscv:trixie ~/xen-domu-build/kernel/builder
```

`--load` matters: with the containerd/buildx driver, a plain `docker build -t`
leaves the image in the build cache only, and the later `docker run` fails with
"pull access denied".

Source:

```bash
cd ~/xen-domu-build/kernel
curl -LO https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.6.tar.xz
curl -LO https://cdn.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc
grep linux-7.2.6.tar.xz sha256sums.asc | sha256sum -c -
tar xf linux-7.2.6.tar.xz
```

Config and build, which is what `build.sh` runs:

```bash
cp container.config ~/xen-domu-build/kernel/container.config

docker run --rm -u "$(id -u):$(id -g)" \
  -v ~/xen-domu-build/kernel:/work -w /work/linux-7.2.6 \
  -e ARCH=riscv -e CROSS_COMPILE=riscv64-linux-gnu- kbuild-riscv:trixie \
  bash -c 'make -s mrproper &&
           scripts/kconfig/merge_config.sh -m arch/riscv/configs/defconfig /work/container.config &&
           make olddefconfig'

docker run --rm -u "$(id -u):$(id -g)" \
  -v ~/xen-domu-build/kernel:/work -w /work/linux-7.2.6 \
  -e ARCH=riscv -e CROSS_COMPILE=riscv64-linux-gnu- kbuild-riscv:trixie \
  bash -c 'make -j20 Image Image.gz'
```

Note `merge_config.sh -m` followed by `make olddefconfig`: `-m` only merges the
files, it does not run kconfig, so the `olddefconfig` afterwards is what resolves
dependencies and is where a symbol with an unmet dependency quietly disappears.

Artifacts land in `arch/riscv/boot/Image` and `arch/riscv/boot/Image.gz`.

## Timings

Cross build on x86_64 (WSL2, 20 cores, `make -j20`) inside Docker. Measured with
bash `time` **inside** the container, so the CPU figures are the build's and not
the docker client's. One run each.

| Step | Wall | CPU (user+sys) |
| --- | --- | --- |
| `mrproper` + `merge_config.sh` + `olddefconfig` | 32.4s | 25.1s (14.7 user, 10.4 sys) |
| `make -j20 Image Image.gz` | 8m 22s | 119m 01s (100m 42 user, 18m 19 sys) |

For reference, the first (untimed-inside) full build measured 8m 35s wall from
the host, which agrees.

A caveat on the artifacts: the timed run rebuilt the same configuration from
scratch and produced an `Image` with a different sha256 from the one shipped here,
because the kernel embeds a build timestamp and a build counter (`#1` vs `#2`).
The `.config` was byte-identical. The shipped `Image`/`Image.gz` are from the
first build, which is also the one that was booted in QEMU.

## Merging the fragment into somebody else's tree

```bash
cd <their-kernel-tree>
ARCH=riscv scripts/kconfig/merge_config.sh -m <base-config> /path/to/container.config
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
```

where `<base-config>` is their `.config` or `arch/riscv/configs/defconfig`. Then
check that nothing was dropped:

```bash
python3 check-fragment.py container.config .config .
```

It prints one line per symbol and exits 1 if any symbol did not get the requested
value. The third argument (the kernel source dir) is optional and makes it
distinguish "symbol does not exist in this tree" from "symbol was dropped".

Two things the fragment assumes about the base config: `CONFIG_MODULES` may be
anything, but nothing in the fragment is `=m`, since the initrd will not load
modules; and it expects a riscv defconfig-like base for drivers (serial, virtio),
which it does not itself set.

## Fragment check

141 symbols, 141 with the requested value, nothing dropped. Full listing in
`fragment-check.txt`.

Two symbols were in the first draft and were removed rather than "fixed", because
they do not exist in 7.2.6:

* `CONFIG_CGROUP_NS` has no Kconfig symbol at all. Cgroup namespaces are built
  unconditionally: `kernel/cgroup/Makefile` line 2 has `namespace.o` in `obj-y`.
* `CONFIG_CRYPTO_GHASH` was folded into `CONFIG_CRYPTO_LIB_GF128HASH`
  (`lib/crypto/Kconfig`), which `CONFIG_CRYPTO_GCM` selects (`crypto/Kconfig:776`).
  It is `=y` in the final config under the new name.

The one non-obvious thing the fragment has to do: since the xtables-legacy split,
`IP_NF_FILTER`, `IP_NF_NAT`, `IP_NF_MANGLE`, `IP_NF_RAW` and the IPv6 equivalents
`depends on IP_NF_IPTABLES_LEGACY`, which in turn `depends on
NETFILTER_XTABLES_LEGACY` (`net/ipv4/netfilter/Kconfig:16,187,224`,
`net/netfilter/Kconfig:747`). Without those two switches every legacy table is
dropped silently, and both check scripts then report the tables as missing. The
riscv `defconfig` itself has this problem: it carries `CONFIG_IP_NF_FILTER=m` with
no legacy switch, so that line does nothing.

`CONFIG_RT_GROUP_SCHED` is deliberately left out even though k3s check-config
lists it as optional. `Documentation/admin-guide/cgroup-v2.rst:1109` says that
with it enabled, the cgroup v2 cpu controller can only be enabled when every
realtime process is in the root cgroup. We are cgroup v2 only and want the cpu
controller.

## check-config results

Both scripts were run offline against `config-7.2.6`. Commands, provenance and
per-item reasoning are in `check-config-moby.txt` and `check-config-k3s.txt`.

Shared caveat: both read the *running* system for some of their output (cgroup
hierarchy, sysctls, swap, `uname -r`, apparmor). Those lines describe the WSL2
host or the container they ran in, not the kernel being checked, and they will
have to be re-checked on the real boot. Every version gate in both scripts is for
5.x or older, so the host reporting 6.6.x instead of 7.2.6 did not change any
branch.

**moby**: everything under "Generally Necessary" enabled. Two optional items
missing:

* `CONFIG_IP_SCTP`: not enabled. Kubernetes supports SCTP service ports, but
  nothing in a single-node no-network test uses SCTP. Add `CONFIG_IP_SCTP=y` to
  the fragment if that ever changes.
* `CONFIG_CRYPTO_GHASH`: renamed, see above. Cosmetic.

One line worth knowing about rather than fixing: `CONFIG_BTRFS_FS` shows "enabled
(as module)". That comes from the riscv defconfig, not from our fragment, and it
will not load, since the initrd has no modules. Overlayfs, the storage driver the
container runtimes actually use here, is built in.

**k3s**: `STATUS: pass`. Three optional items missing:

* `CONFIG_RT_GROUP_SCHED`: deliberate, see above.
* `CONFIG_CRYPTO_GHASH`: renamed.
* `CONFIG_INET_XFRM_MODE_TRANSPORT`: the symbol does not exist anywhere in the
  7.2.6 tree (grep over all `Kconfig*` returns nothing). Removed upstream years
  ago. It only matters for encrypted overlay networks.

Getting `k3s check-config` to read a file offline needed one trick, which is
written up in `check-config-k3s.txt`: the script takes the config path as `$1`,
but the Go wrapper's `findDataDir()` (`cmd/k3s/main.go:121`) also scans argv and
ends up treating that path as a data directory, so it tries to unpack the k3s
bundle into `<your-config-path>/data`. Setting `K3S_DATA_DIR` makes `findDataDir`
return early and the argument then only reaches the script.

The k3s binary is the riscv64 one from the release named in the brief, run under
binfmt/QEMU emulation; its sha256 matched the `.sha256sum` asset.

## Xen on riscv: what the tree says

Research only, no patches. All paths are in linux-7.2.6.

* `CONFIG_XEN` is defined in exactly three places: `arch/x86/xen/Kconfig:6`,
  `arch/arm/Kconfig:1349` and `arch/arm64/Kconfig:1677`. There is no definition
  under `arch/riscv`, so on riscv the symbol does not exist.
* `drivers/xen/Kconfig` opens with `menu "Xen driver support"` / `depends on XEN`,
  and it is sourced unconditionally from `drivers/Kconfig:156`. With no `XEN`
  symbol on riscv, that whole menu, and every Xen frontend
  (`drivers/block/Kconfig:278` blkfront, `drivers/net/Kconfig:546` netfront,
  `drivers/tty/hvc/Kconfig:54` HVC_XEN), is unreachable.
* There is no `arch/riscv/xen/` directory and no `arch/riscv/include/asm/xen*`
  header. The only hypervisor-adjacent riscv header is
  `arch/riscv/include/asm/paravirt.h`.
* `CONFIG_PARAVIRT` does exist for riscv (`arch/riscv/Kconfig:1127`) but it is not
  related to Xen: it `depends on RISCV_SBI` and its implementation
  (`arch/riscv/kernel/paravirt.c`) is SBI steal-time accounting via the SBI STA
  extension. arm64 by contrast does `select PARAVIRT` from its `XEN` symbol.

Checked empirically as well: appending `CONFIG_XEN=y`, `CONFIG_HVC_XEN=y` and
`CONFIG_XEN_BLKDEV_FRONTEND=y` to a riscv `.config` and running `make ARCH=riscv
olddefconfig` leaves no `CONFIG_XEN*` line of any kind in the result.

So a stock riscv64 kernel has no Xen guest support to enable: no grant tables, no
xenbus, no event channels, no PV console, no PV block or net. Whether it can still
boot as a dom0less domU depends entirely on how much of a plain "hardware" machine
Xen presents to the guest on riscv, and on what console and devices it exposes.
That is the question for Baptiste; nothing in this tree answers it.

One thing to keep in mind for that conversation: this kernel's console is the
8250 UART (`console=ttyS0`, confirmed below). If a riscv domU gets neither an
emulated 8250 nor a Xen PV console, the kernel would still boot but print nothing.
The tree does have an SBI console path (`CONFIG_HVC_RISCV_SBI`,
`drivers/tty/hvc/Kconfig:109`, and `CONFIG_SERIAL_EARLYCON_RISCV_SBI`, which is
already `=y` here via defconfig), but `HVC_RISCV_SBI` also `depends on
NONPORTABLE`, which is not set. Deliberately not enabled, and untested: whether
Xen provides SBI DBCN to a domU is exactly the sort of thing to ask rather than
guess.

## Booting it

```bash
qemu-system-riscv64 -M virt -m 2048 -smp 2 -nographic \
  -kernel Image \
  -initrd <the-initrd.cpio.gz> \
  -append "console=ttyS0 rdinit=/init"
```

`console=ttyS0` is correct: `CONFIG_SERIAL_8250`, `CONFIG_SERIAL_8250_CONSOLE` and
`CONFIG_SERIAL_OF_PLATFORM` are all `=y` (they come from the riscv defconfig), and
a boot on `-M virt` shows `10000000.serial: ttyS0 at MMIO 0x10000000 ... is a
16550A` followed by `printk: legacy console [ttyS0] enabled`. See
`qemu-smoke-test.txt`. QEMU 10.0.13 supplies its built-in OpenSBI as firmware, so
no `-bios` is needed.

That smoke test had no initrd, so it ends in `VFS: Unable to mount root fs`, which
is the expected outcome and the furthest this part of the work could verify alone.
It has since been booted for real; see "Boot results" below, and take the `-m 2048`
above from there rather than from the smoke test, which used 1G.

`CONFIG_RD_GZIP=y` for a `.cpio.gz` initrd; the defconfig also brings BZIP2, LZMA,
XZ, LZO, LZ4 and ZSTD, so any of those formats would work too.

## Boot results

Measured by the initrd agent, not by me, over six boots of this `Image` under
`qemu-system-riscv64 -M virt` (TCG, no NIC, no disk) with their 204 MiB
`initrd.cpio.gz`. Their full console log is `initrd/boot-test-all.log`.

* Docker, single-node K3s and a pod all came up: `DOCKER_OK`, `K3S_OK`,
  `PAYLOAD_DONE`, then a clean poweroff.
* Memory: `-m 2048` is comfortable, peak 976 MiB of 1966 for the full run. K3s
  alone passed at `-m 1536` (peak 943 MiB). Docker alone peaked at 325 MiB. 1 GiB
  is too tight for K3s, and the 4 GiB I guessed at is not needed.
* The initramfs-to-tmpfs handover does not double memory use: their `/init` copies
  only the directories it is itself executing from and `tar --remove-files`-moves
  the rest, measured at 605 MiB before and 570-646 MiB after.

Things flagged below that are now confirmed on the running system rather than read
off the config: devpts mounted with no symbol to enable, overlayfs worked on the
tmpfs root (dockerd reported storage driver `overlayfs`, no vfs fallback, so
`TMPFS_XATTR` is earning its place), `Seccomp: 2` / `Seccomp_filters: 1` inside a
container, runc started containers so `CGROUP_BPF` is satisfied, cgroup v2
delegated `cpuset cpu io memory hugetlb pids`, and busybox `poweroff -f` works
without `MAGIC_SYSRQ`.

## Things worth flagging to whoever boots this

Not verified here, but they follow from the config and will be met immediately.

* **pivot_root on an initramfs rootfs.** runc pivot_roots by default, and that
  fails on the initramfs rootfs because it cannot be unmounted. The usual fix is
  for `/init` to mount a tmpfs, populate it and `switch_root` into it, so the
  container runtime is working on a normal mount. `CONFIG_TMPFS`,
  `CONFIG_TMPFS_XATTR` and `CONFIG_TMPFS_POSIX_ACL` are `=y` for that, and the
  xattr part is not optional: overlayfs keeps its metadata in `trusted.*` xattrs.
* **No modules.** `CONFIG_MODULES=y` is inherited from defconfig, but the initrd
  has no `/lib/modules`, so anything that is `=m` in `config-7.2.6` (btrfs, kvm,
  dm, several netfilter leftovers) is unavailable. Everything the container
  runtimes need is `=y`.
* **LSMs are compiled in but not active.** `CONFIG_SECURITY_SELINUX=y` and
  `CONFIG_SECURITY_APPARMOR=y` come from defconfig, but
  `CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,ipe,bpf"` lists neither,
  so neither is enabled unless an `lsm=` boot argument adds it. Practical effect:
  Docker should not demand `apparmor_parser`, and there is no MAC confinement.
* **K3s wants a default route.** It picks a node IP from the default route, and a
  guest with no NIC has none. `CONFIG_DUMMY=y` is in the fragment so a dummy
  interface can carry one.
* **cgroup v2 only.** Nothing here mounts cgroups; the init has to mount
  `cgroup2` on `/sys/fs/cgroup` and the cpu, cpuset, memory, pids and io
  controllers need enabling in `cgroup.subtree_control` before a runtime will use
  them.

## What was not verified

* I did not boot this kernel with a real initrd myself. It has been booted, with
  Docker and K3s both running on it, but by the initrd agent; see "Boot results".
  Everything in this file other than that section is from the config, the source
  tree or my own no-initrd smoke test.
* No Xen anywhere: no domU boot, no Xen build, nothing beyond reading this
  kernel's Kconfig.
* The kernel.org tarball's PGP signature was not verified, only its sha256.
* Only one timing run per step, on a machine that was also running other work.
* `check-config-moby.txt` was produced with moby's `master` version of the script
  (commit `a4c5b2be6f69`, its last change 2026-06-16), not a release tag.

## 2026-09-20: SBI console for a Xen domU, and a rebuild

`container.config` gained `CONFIG_RISCV_SBI_V01=y` and
`CONFIG_SERIAL_EARLYCON_RISCV_SBI=y`, and the kernel was rebuilt with them
(6m10s wall, cross on x86_64, 20 jobs). `check-fragment.py`: 143 symbols, 143 ok.

Why: Xen's virtual SBI for guests implements only the legacy console calls
(`xen/arch/riscv/vsbi/legacy-extension.c` handles SBI_EXT_0_1_CONSOLE_PUTCHAR and
GETCHAR), with no SBI_EXT_DBCN handler. Linux 7.2.6's earlycon falls back to
`sbi_console_putchar()` when DBCN is unavailable, and that function exists only under
CONFIG_RISCV_SBI_V01; otherwise `asm/sbi.h` compiles it to an empty stub, so a domU
whose only console is SBI prints nothing at all. HVC_RISCV_SBI is not an alternative:
it calls `sbi_debug_console_write()` and also depends on NONPORTABLE.

Untested: anything under Xen. A guest given a passthrough UART would not need this,
and 8250 stays enabled for QEMU virt either way. Read from the Linux 7.2.6 and
xen-project/xen trees, not measured on a hypervisor.

`build.sh` now copies Image, Image.gz and the .config next to itself as step 3. It
did not before, so a rebuild left stale artifacts in this directory while the fresh
ones sat in the work tree.
