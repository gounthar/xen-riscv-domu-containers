# Running the container payload in a RISC-V guest

A short guide to booting this payload, aimed at someone already working on Xen for
RISC-V. It covers what the payload is, how to configure a guest kernel that can run
containers, the exact command lines, how much memory each variant needs, and the
several ways a boot can fail while looking like it worked.

## Credit, and what this is not

The hypervisor work is not mine. Xen on RISC-V, dom0 support, guest domains and the
SiFive P550 bring-up are Oleksii Kurochko's and Baptiste Le Duc's, at Vates. This
document sits entirely on top of their trees:

- `github.com/baptleduc/linux-xen-riscv`, branch `6.18-xen-guest-support`
- `gitlab.com/xen-project/people/olkur/xen`, branch `dev-riscv-support-guest-domains`

What is mine is the payload in this directory, the kernel config fragment in
`kernel/container.config`, and the measurements below.

Everything here was measured on `qemu-system-riscv64 -M virt` under TCG on an x86_64
host, with no hypervisor, except where a section says otherwise. **The payload has not
yet been booted as a domU**, and no PV network or PV disk has been exercised on this
port by anyone. Treat the numbers as a starting point that will need re-checking under
Xen, not as domU results. The final section of this document lists what is untested;
it is longer than it looks and worth reading before relying on anything here.

## What the payload is

A kernel and an initrd that boot straight into three tests, print greppable markers on
the serial console, and power off:

- `docker run hello-world`, plus a seccomp filter verified inside a container,
- the same `hello-world` image run as a pod by a single-node K3s cluster,
- a block device round trip, raw and through a filesystem.

It works in a guest with no disk and no network device, and it uses both if they are
there. The root filesystem lives in RAM and nothing is mounted from a disk unless a
block device is handed to it. If there is a real network interface it is used; if
there is not, a `dummy0` with a static address stands in, because K3s refuses to start
without a default route. Container images are imported from tarballs in the image;
nothing is ever pulled, which is why the K3s pod sets `imagePullPolicy: Never`.

## The four variants, and which test each one runs

Pick the smallest variant that runs the test you want. This matters more than it
sounds: the split into variants is what brought the K3s floor down by 320 MiB.

| archive | `test=` to pass | contents |
|---|---|---|
| `initrd-docker.cpio.gz` | `test=docker` | Docker engine, one busybox image. No K3s. |
| `initrd-k3s.cpio.gz` | `test=k3s` | K3s and its four airgap images. No Docker. |
| `initrd.cpio.gz` | `test=all` | both stacks, plus the disk test |
| `initrd-full.cpio.gz` | `test=k3s k3s.full=1` | `all` plus traefik, servicelb, metrics-server |

`.cpio.zst` versions of each exist for kernels with `CONFIG_RD_ZSTD=y`. They have
never been booted.

Asking for a test the image cannot run is handled rather than mysterious: the payload
reads its variant from its own manifest, reduces `test=all` to whatever the image can
do, and says so on the console.

| variant | `gzip -9` |
|---|---|
| `docker` | 83 363 651 B |
| `k3s` | 146 085 780 B |
| `all` | 205 016 731 B |
| `full` | 353 327 164 B |

Those are current as of the last rebuild; `initrd/NOTES.md` carries the unpacked
sizes, file counts and checksums and is regenerated with them, so check there rather
than here if the numbers matter.

## The guest kernel

### The fragment, and how to merge it

`kernel/container.config` is 143 symbols covering what Docker's and K3s's own
config checkers call generally necessary, plus what runc needs on cgroup v2, plus a
few things this particular setup needs because its root is an initrd with no module
loading.

It merges onto `xen_defconfig` cleanly. Measured on
`6.18-xen-guest-support` at HEAD `048308d86`: **143 of 143 symbols present in the
final `.config`, none dropped, none missing from the tree.**

```bash
make O=$BUILD ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- xen_defconfig
ARCH=riscv scripts/kconfig/merge_config.sh -O $BUILD -m \
    $BUILD/.config kernel/container.config
make O=$BUILD ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
make O=$BUILD ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j"$(nproc)" Image Image.gz
```

`kernel/check-fragment.py` will tell you whether anything was dropped, which
`merge_config.sh` will not: it warns and then exits 0 either way.

```bash
python3 kernel/check-fragment.py kernel/container.config $BUILD/.config /path/to/linux
```

The third argument is optional and worth passing: with it, a symbol that does not
exist in the tree is reported as "no such symbol" rather than as "dropped", which are
different problems.

### Why `xen_defconfig` alone is not enough

Not a criticism of the config, which was not written with containers in mind. These
are the gaps, measured by diffing the two generated `.config` files:

| symbol | `xen_defconfig` | with the fragment |
|---|---|---|
| `OVERLAY_FS` | `m` | `y` |
| `VETH` | `m` | `y` |
| `BRIDGE` | `m` | `y` |
| `VXLAN` | `m` | `y` |
| `NETFILTER_XTABLES_LEGACY` | `n` | `y` |
| `IP_NF_IPTABLES_LEGACY` | not present at all | `y` |
| `NF_TABLES` | `n` | `y` |

Two traps in that table.

**`=m` is the same as absent here.** The guest root is an initrd unpacked into RAM
with no `/lib/modules` and no module loading, so a module is a file that never gets
loaded. Overlayfs in particular is not optional: without it a container runtime falls
back to `vfs` if it starts at all. The fragment builds all four in. If you prefer to
keep them as modules for another use case, you will need to ship a modules tree and a
`modprobe` in the initrd.

**The legacy iptables tables disappear silently.** Since the xtables split, the legacy
tables only exist when `NETFILTER_XTABLES_LEGACY` and `IP{,6}_NF_IPTABLES_LEGACY` are
set. Without them `merge_config` quietly drops `IP_NF_FILTER`, `IP_NF_NAT`,
`IP_NF_MANGLE`, `IP_NF_RAW` and the IPv6 equivalents, which are exactly the symbols
both container config checkers look for. Note that `IP_NF_IPTABLES_LEGACY` does not
appear in the stock config in either form, not even as `# ... is not set`, because it
is hidden by `NETFILTER_XTABLES_LEGACY=n`. Grepping for it finds nothing and it is
easy to conclude the symbol does not exist.

The fragment does not disturb any Xen or console symbol. `XEN`, `XEN_DOM0`,
`NONPORTABLE`, `RISCV_SBI_V01`, `HVC_RISCV_SBI`, `HVC_XEN`, `HVC_XEN_FRONTEND`,
`XEN_NETDEV_FRONTEND`, `XEN_BLKDEV_FRONTEND`, `XEN_GNTDEV`, `XEN_PRIVCMD` and
`XEN_BALLOON` are all `y` before and after.

### A note on `xen_domain_type`

On `6.18-xen-guest-support` as it stands, a kernel built from `xen_defconfig` boots
only under Xen. `arch/riscv/kernel/setup.c:329` calls `xen_early_init()`
unconditionally, `arch/riscv/xen/enlighten.c:165` sets `xen_domain_type =
XEN_HVM_DOMAIN` with no check, the static initialiser at `enlighten.c:42` does the
same, and the device-tree guard `fdt_find_hyper_node()` is stubbed to `return 0`, so
the absence of a hypervisor cannot be detected. `xen_guest_init()` then runs its body
and calls `BUG()` when `HYPERVISOR_memory_op(XENMEM_add_to_physmap, ...)` returns
`-ENOENT`.

That is entirely reasonable for work in progress. It is worth knowing because it
means you cannot smoke-test the guest kernel on plain QEMU or on hardware, only under
Xen, and because the failure is invisible without `earlycon` (see below). If you want
a plain-virt control build, both the static initialiser and the `xen_early_init()`
assignment have to go; changing only one leaves `xen_domain()` returning true and the
`BUG()` still fires.

## Booting it on plain QEMU

This is the configuration everything below was measured on.

```bash
qemu-system-riscv64 -M virt -m 1152 -smp 4 -nographic -no-reboot -nic none \
  -kernel Image \
  -initrd initrd-k3s.cpio.gz \
  -append "console=ttyS0 earlycon=uart8250,mmio,0x10000000 keep_bootcon \
           test=k3s k3s.timeout=5400 k3s.podtimeout=2400 progress=60"
```

`-no-reboot` matters: the payload powers off when it finishes, and without it QEMU
restarts the guest instead of exiting. `-nic none` is deliberate, to match a guest
with no PV network.

In a container, if you would rather not install QEMU:

```bash
docker build -t xen-domu-qemu - <<'EOF'
FROM debian:trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-misc opensbi && rm -rf /var/lib/apt/lists/*
EOF
```

`validation/harness/run-boot.sh` wraps this and writes a log plus a `.meta` file
recording the exact invocation, the input checksums, the exit code and the wall time.
`validation/harness/analyse.py` summarises a log, and it strips the carriage returns
the serial console emits, which a naive `grep '^K3S_OK$'` will not match.

## Pass `earlycon` from the very first boot

This is the single piece of advice most worth taking from this document.

Everything interesting that can go wrong in a RISC-V guest goes wrong before the 8250
console registers at `device_initcall`. With only `console=ttyS0`, every one of those
failures looks identical: the OpenSBI banner, then nothing, for as long as you are
willing to wait. A hang, a panic in an `early_initcall`, and a trap in `setup_arch`
are indistinguishable.

Adding one flag turns that into a stack trace:

```
earlycon=uart8250,mmio,0x10000000        # plain -M virt
earlycon=sbi                             # a Xen guest using the SBI console
```

Both drivers are in the tree: `EARLYCON_DECLARE(sbi, ...)` in
`drivers/tty/serial/earlycon-riscv-sbi.c` and `EARLYCON_DECLARE(xenboot, ...)` in
`drivers/tty/hvc/hvc_xen.c`. For a domU I would reach for `earlycon=sbi` rather than
`earlycon=xenboot`, because `xenboot` needs the Xen PV console ring and that is
plausibly the thing you are debugging. `xen_defconfig` already sets
`CONFIG_RISCV_SBI_V01=y`, which the SBI console path needs. I have not yet confirmed
this under Xen.

Add `keep_bootcon` so the early console is not unregistered when the real one appears.

## Memory

### The floors

Bisected on the artifacts in this directory, `-M virt -smp 4`, TCG. A boot counts as a
failure whenever the kernel logged `Initramfs unpacking failed`, whatever else it
printed.

| variant | test | lowest that passes | highest that fails |
|---|---|---|---|
| `docker` | `test=docker` | **560 MiB** | 544 MiB |
| `k3s` | `test=k3s` | **1024 MiB** | 960 MiB |
| `all` | `test=all` | **1248 MiB** | 1216 MiB |
| `full` | `test=k3s` | **1728 MiB** | 1664 MiB |

Those are tight. The `docker` variant passes at 560 MiB with 1 MiB of rootfs to spare.
Round numbers to actually use:

> `docker` 640 MiB, `k3s` **1152 MiB**, `all` 1344 MiB, `full` 1792 MiB.

### The formula, which is more useful than the table

With no `root=` and no `rootfstype=`, the kernel makes the initramfs rootfs a tmpfs
sized at half the free memory at the moment it is mounted. The compressed initrd is
still resident at that moment, so:

```
rootfs cap  =  (MemTotal - compressed initrd size) / 2

boot succeeds when  MemTotal >= 2 x unpacked size + compressed size
```

Measured against every boot in `initrd/NOTES.md`, that model is right to within 1 or
2 MiB. It also held on a 6.18 kernel it was never fitted to: at `-m 1152` with the
`k3s` variant it predicts `(1085 - 139) / 2 = 473 MiB` and the kernel reported 472.

Use the formula rather than the table when you change anything, because shrinking the
image pays twice: 2 MiB off the unpacked tree is 4 MiB off the floor, plus whatever
comes off the archive.

`/init` prints the cap, used and free on every boot, on the line straight after
`PAYLOAD_START`:

```
PAYLOAD_START
[     4.57] rootfs (initramfs): rootfs 210M total, 209M used, 1M free; MemTotal 503M
```

A boot that fails with 0M free was short of RAM for the unpack. A boot that fails with
room to spare was short of RAM for the test. The two need different fixes.

### `initramfs_options=`, and what does not work

`initramfs_options=size=90%` reaches the initramfs rootfs mount and lifts the
half-of-RAM cap. It converts a silent truncation into an honest OOM, which is an
improvement, but it does not buy as much as it looks like it should, because the
compressed initrd is still resident.

`rootflags=size=90%` does **not** reach that mount. It is silently ignored. This was
tried and measured, not assumed.

## The failure that looks like a pass

Read this before trusting any result.

When the image does not fit in the rootfs cap, the kernel prints one line and carries
on booting:

```
Initramfs unpacking failed: write error
```

Userspace then starts on a partial filesystem. What that looks like depends only on
where in the archive the cut landed, and cpio archives are in sorted order, so it is
the same cut every time. On the older single combined image, `dockerd` sat immediately
before the K3s tree, so a truncation took K3s first and left Docker whole: a
`test=docker` boot printed `DOCKER_OK` and powered off cleanly on an image missing a
third of its files, at every size from 768 to 1024 MiB. Nothing in that console log
says the image was incomplete except the kernel line, 200 lines earlier.

The rule that follows:

> **Any boot whose log contains `Initramfs unpacking failed` is a failure, whatever
> markers it printed.**

The current payload enforces this itself. `/init` checks, in stage 1 before any test,
both the kernel log and a manifest built into the image at `/etc/payload-manifest`
containing a sentinel file whose name sorts last under `LC_ALL=C`, the sizes of 17 to
22 critical files, and the total file count and byte total. On a complete image you
get:

```
payload: image intact (variant k3s, 1540 files, 340458899 bytes, 20 named files, ...)
```

and on an incomplete one you get `PAYLOAD_FAIL: initrd truncated (<detail>)` and
nothing else. Keep that check; it is the difference between a measurement and a guess.

`PAYLOAD_START` means the kernel reached userspace and nothing more. It is printed on
an image missing a third of its files.

## Command line options

All parsed from `/proc/cmdline` by `/init`. Unknown words are ignored, so it is safe
to keep `console=`, `earlycon=` and the rest. The kernel will log
`Unknown kernel command line parameters "test=k3s progress=60"` and that is correct
and harmless.

| option | default | meaning |
|---|---|---|
| `test=all\|docker\|k3s\|disk` | `all` | which tests to run |
| `debug=1` | off | drop to a shell instead of powering off, including after a failure |
| `keep=1` | off | do not delete the unused stack or the imported image tars |
| `k3s.full=1` | off | do not disable traefik, servicelb and metrics-server |
| `k3s.cfgtimeout=SEC` | 120 | budget for the K3s server to write its kubeconfig; raise it under Xen (see below) |
| `k3s.restarts=N` | 0 | restart the K3s server up to N times if it exits; a server that exits is now reported at once rather than waited on |
| `k3s.timeout=SEC` | 1800 | budget for the node to reach Ready |
| `k3s.podtimeout=SEC` | 900 | budget for the test pod |
| `docker.timeout=SEC` | 600 | budget for each `docker run` |
| `docker.storage=NAME` | probe | force a storage driver instead of probing overlayfs |
| `root.size=SIZE` | 90% | size of the tmpfs the real root lives in |
| `net.addr=CIDR` | 10.0.2.15/24 | address on the chosen interface |
| `net.gw=IP` | 10.0.2.2 | gateway for the default route |
| `disk.dev=PATH` | `/dev/xvda` | block device for the disk test |
| `disk.timeout=SEC` | | budget for the disk test |
| `k3s.role=server\|agent` | `server` | `agent` joins an existing server instead of running the test; see "Two domUs, one cluster" |
| `k3s.server=URL` | | agent only: the server to join, e.g. `https://192.168.128.2:6443` |
| `k3s.token=TOKEN` | | join token, passed to both roles when set |
| `k3s.nodename=NAME` | `domu` | node name and the `/etc/hosts` entry for this guest |
| `k3s.nodes=N` | `1` | server: wait for N Ready nodes before running the pod |
| `k3s.podnode=NAME` | | server: pin the test pod to this node with a `kubernetes.io/hostname` nodeSelector |
| `k3s.agenthold=SEC` | `180` | agent: stay up this long after its container ran, so the server can still read the logs |
| `net.ping=IP` | | ping this address once the network is up, before the tests; reports `PING_OK` or `PING_FAIL` |
| `net.pingsize=N` | `1000` | payload bytes for that ping. Above netback's header-copy length on purpose, so the frame's page is grant-mapped |
| `net.pingcount=N` | `5` | how many |
| `net.hold=SEC` | `0` | stay up this long before powering off, so another guest can reach this one |
| `progress=SEC` | 30 | interval between progress lines |

Everything is slow under TCG. Raise the timeouts rather than concluding a hang:
progress lines carry a timestamp, the elapsed and budget counters, the last K3s log
line and the memory left, so slow progress and a real hang look different.

`debug=1` is the one to reach for when something fails and you want to poke around.


## Two domUs, one cluster

The same payload runs both halves of a two-node K3s cluster, one node per domU, joined over
the PV network. Measured on QEMU TCG (fedora1, dom0 plus `xl create`), runs 43-48: the server
side passed 6/6 and 3/3 of those were confirmed independently from the agent guest.

Server guest:

```
extra = "console=hvc0 earlycon=sbi test=k3s net.addr=192.168.128.2/24 net.gw=192.168.128.1 \
k3s.token=SHARED k3s.nodes=2 k3s.podnode=domu2 k3s.cfgtimeout=1800 k3s.restarts=3 \
k3s.timeout=5400 k3s.podtimeout=2400 progress=60"
```

Agent guest:

```
extra = "console=hvc0 earlycon=sbi test=k3s net.addr=192.168.128.3/24 net.gw=192.168.128.1 \
k3s.role=agent k3s.server=https://192.168.128.2:6443 k3s.token=SHARED k3s.nodename=domu2 \
k3s.cfgtimeout=3600 k3s.restarts=3 k3s.timeout=5400 k3s.podtimeout=2400 k3s.agenthold=180 \
progress=60"
```

Both need at least the usual RAM (1344 MiB each here); the agent is not cheaper, because the
initrd still unpacks in full. Start the agent first and the server second: the agent retries
the join for `k3s.cfgtimeout` seconds, so the order is not critical, but the server's console
is the one worth attaching to.

What each side reports, and why both are worth having:

- The **server** prints `k3s: pod ran on node: domu2` and one line per node, then reads the
  pod's logs. That read goes from its apiserver to the other guest's kubelet, so it crosses
  the PV network between two domUs.
- The **agent** has no admin kubeconfig. It reports only what it can see locally: the kubelet
  kubeconfig (which the server hands out only once the token checks out), then the test
  container in its own containerd, through `crictl`, with its output. It then stays up for
  `k3s.agenthold` seconds so the server's log read still works.

Only the agent's `crictl` line proves the container ran *there* without trusting the server's
view of it. Note that `crictl` must be called through `bin/crictl`: `bin/k3s` picks its tool
from `argv[0]`, so `k3s crictl ps` runs crictl with `crictl` as its first argument and fails
with `No help topic for 'crictl'`.

**On riscv Xen this needs a hypervisor change that is not upstream.** The first frame large
enough to be grant-mapped between two guests reaches `page_get_owner_and_reference()`, an
`assert_failed()` stub in `xen/arch/riscv/mm.c`, and the hypervisor stops there. `net.ping`
exists to test exactly that without K3s: two guests, one pinging the other with 1000-byte
payloads, passes 5/5 with the stub replaced by ARM's one-line definition and asserts at the
first ping without it (runs 49 and 50). Dom0-to-guest traffic never takes that path, which is
why the single-guest tests never saw it.

## Markers

Each on its own line, in this order:

```
PAYLOAD_START
PAYLOAD_FAIL: initrd truncated (<detail>)     (and then nothing else)
PING_OK: <ping summary>  or  PING_FAIL: <reason>   (only with net.ping=)
DISK_OK          or  DISK_FAIL: <reason>      (skipped if there is no block device)
DOCKER_OK        or  DOCKER_FAIL: <reason>
K3S_OK           or  K3S_FAIL: <reason>
SUMMARY: docker=... k3s=... disk=...
PAYLOAD_DONE
```

With `k3s.role=agent` the K3s field carries the node name, `k3s=ok (agent domu2)`, and
`K3S_OK` there means the agent joined, saw the test container in its own containerd and
read the expected output out of it.

`SUMMARY` has three fields. Anything matching the older two-field string will not
match. The disk test runs first in `test=all`: it is the cheapest, it is independent
of the other two, and a disk failure should not sit behind six minutes of K3s.

The markers are printed by `/init` itself, never by a container, and only after the
result has been checked. The Docker test runs `hello-world` with **no command**, so the
image's own entrypoint executes, captures its stdout, and matches it against
`Hello from Docker!` before the marker is reachable. It additionally requires
`Seccomp: 2` in `/proc/self/status` inside a container — that check uses busybox,
because `hello-world` exits immediately and has no shell to read `/proc` from. The K3s
test runs the same image as a pod with `imagePullPolicy: Never` and matches
`kubectl logs` the same way. `DISK_OK` requires a raw write and read-back with matching
sha256 **and** a mkfs, mount, write, unmount, remount, read-back of a per-boot random
nonce.

So `grep -c '^DOCKER_OK$'` on the console log is 1 on success and 0 otherwise.

When grepping, anchor to the whole line. This matters more than it sounds: a
`DOCKER_FAIL` message quotes what was expected, so a **failing** log contains the
string `Hello from Docker!` twice and a careless substring search reads it as a pass.

After `PAYLOAD_DONE` the guest powers off, so QEMU exits on its own.

## Notes for the dom0 and domU path

These come from getting Xen, dom0 and this payload assembled with the
`automation/build/debian/trixie-riscv64` tooling. They are things that cost time and
would have been invisible.

**Status 2026-09-21:** a domU now boots through dom0 to userspace under QEMU TCG and
passes the Docker and K3s tests (`SUMMARY: docker=ok k3s=ok disk=skipped`, on a native
Linux host; see "Host speed decides K3s" below). Getting there
needed the three subsections that follow this paragraph, two of which change code in
Xen's toolstack or the guest kernel. netfront and blkfront are **not** shown; see "What
has not been tested".

### Without `sstc` the guest can livelock under TCG, and the workaround is only safe for one vCPU

`tools/libs/light/libxl_riscv.c:25` hardcodes the domU's `riscv,isa` as
`"rv64imafdc_ssaia"`. Xen already enables the extension for every guest vcpu
(`xen/arch/riscv/domain.c:523`, `ENVCFG_STCE`) and dom0 gets it from the host device
tree, but the domU is not told (the string read `"rv64imafdc_sstc"` until a later
commit removed `sstc`, consistent with guest Sstc being unsupported, see below). Linux then programs its timer through SBI
`set_timer`, two world switches per tick. Under TCG a tick costs 7-15 ms against a
4 ms period and the guest livelocks one instruction after `local_irq_enable()`: last
line `sched_clock: 64 bits at 10MHz`, QEMU at 100% CPU, nothing more, ever.

Guest-side Sstc is not supported on this branch yet, deliberately: Xen does not save or
restore `vstimecmp` on a context switch, so a guest using Sstc would have its timer
clobbered whenever another vCPU runs on the same physical CPU. The upstream plan lists it
as future work. **The change below is a workaround, safe only with one vCPU per physical
CPU** (we run `sched=null`, `dom0_max_vcpus=1` and a 1-vCPU domU). With it, rebuild the
tools and the dom0 initrd:

```c
{"xen-3.0-riscv64", "riscv,timer", "riscv", "rv64imafdc_ssaia_sstc", "riscv,sv57"},
```

The proof it took is in the guest's own log: a **second**
`riscv-timer: Timer interrupt in S-mode is available via sstc extension` line (the first
is dom0's). On hardware, or on a faster host, the SBI path may be fast enough to boot
without it.

### The event-channel interrupt only clears on a guest exit

With `sstc` the guest stops exiting to Xen on every tick, and that exposes a second
problem. Xen raises the event-channel interrupt by setting `IRQ_VS_EVTCHN` in `hvip`
(`vcpu_mark_events_pending()`, `domain.c:347`) and only ever clears it in
`vcpu_update_evtchn_irq()`, called from `enter_hypervisor_from_guest()`. The guest's
handler clears the pending flag in shared memory and makes no hypercall, so the line
stays asserted and re-fires with no exit to break the loop. Symptom: the guest stops
right after `Xen: initializing cpu0` / `rcu: Hierarchical SRCU implementation.`.

**There is no proper fix yet.** The guest kernel that ran the payload carries an
experiment, not a fix: one hypercall at the end of `xen_riscv_callback()` in
`arch/riscv/xen/enlighten.c`, purely to force an exit:

```c
	xen_evtchn_do_upcall();
	HYPERVISOR_xen_version(XENVER_version, NULL);	/* experiment: force an exit */
```

(plus `#include <xen/interface/version.h>`). The real fix belongs in Xen, with the
authors of the event-channel delivery code. Do not ship the above.

### dom0 needs devpts and `xenconsoled` before `xl create -c`

libxl waits ten seconds for `/local/domain/N/console/tty` and reports
`console tty: timed out`, which names no cause. That node is written by `xenconsoled`,
which ships in the initrd but is not started. Started by hand it fails with
`Failed to create tty for domain-1 (errno = 2)`, because nothing mounts devpts. In
dom0, before the create:

```sh
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts
xenconsoled --pid-file /var/run/xenconsoled.pid
```

Check liveness on the pid file, not with `ps | grep`, which matches itself.

### `libgcc_s.so.1` must be in the dom0 initrd

`xl create` without `-c` creates the domain and then aborts:
`libgcc_s.so.1 must be installed for pthread_cancel to work` (rc=134). glibc
`dlopen`s it, so it appears in no `DT_NEEDED` and no closure check over ELF headers will
find it. Add it to the copy list by hand.

### Drop `keep_bootcon` from the domU command line

`keep_bootcon` with `earlycon=sbi` keeps the SBI console alive after `hvc0` takes over,
and every character becomes an ecall, i.e. a VM exit. A live guest looks hung for tens
of minutes. Keep `earlycon=sbi`, which is what makes a pre-console failure visible;
drop `keep_bootcon`.

### Do not use `xl debug-keys q` on this port

`arch_dump_domain_info()` and `arch_dump_vcpu_info()` are `assert_failed()` stubs, so the
key that dumps domain state halts the hypervisor. Also: `xc_domain_destroy` fails with
`Function not implemented` (`domain_relinquish_resources()` returns `-ENOSYS`), so a failed
create leaves a zombie domain and dom0 must be restarted between attempts.

### Raise `k3s.cfgtimeout` under Xen

The default 120 s for the K3s server to write its kubeconfig ran out under Xen on TCG
while the server was still starting (`server is not ready`, plenty of memory, no OOM).
The domU config used from then on:

```
extra = "console=hvc0 earlycon=sbi test=all net.addr=192.168.128.2/24 net.gw=192.168.128.1 k3s.cfgtimeout=1800 k3s.restarts=3 k3s.timeout=5400 k3s.podtimeout=2400 disk.timeout=900 progress=60"
```

Add `k3s.restarts=3` too: the payload then restarts a K3s server that exits (same data
dir), and in any case stops waiting on a dead one.

### The `block` hotplug script needs `/dev/stdin`

With a `disk =` line, `xl create` fails after a long pause:
`killing execution of /etc/xen/scripts/block add because of timeout`, then the same for
`block remove`. The script is not stuck on the disk. It is stuck in `claim_lock`
(`tools/hotplug/Linux/locking.sh`), which loops until `stat -L /dev/stdin <lockfile>`
succeeds. A dom0 whose `/dev` is only devtmpfs has no `/dev/stdin`, so the loop never
ends. The vif script never takes that lock, which is why networking attaches and the disk
does not. In dom0, before the create:

```sh
ln -sfn /proc/self/fd /dev/fd
ln -sf /proc/self/fd/0 /dev/stdin
ln -sf /proc/self/fd/1 /dev/stdout
ln -sf /proc/self/fd/2 /dev/stderr
```

A dom0 image built from `xen-riscv-builder` after 2026-09-21 does this in its rcS, along
with mounting devpts; four runs with a disk attached completed `block add` with no manual
step.

To see where a hotplug script hangs, trace it to a file before the create, so the trace
survives the kill: `sed -i '1a exec 2>>/var/log/xen/block-trace.log; set -x'
/etc/xen/scripts/block`.

### PV network and PV disk need two grant-table changes (experiments)

As the branches stand, dom0 attaches both the vif and the disk, and the guest then logs
`xen:grant_table: grant table add_to_physmap failed, err=-38`. Every PV frontend fails
after it: `vbd vbd-51712: 28 granting access to 1 ring pages` for the disk, `vif vif-0: no
queues` / `22 creating queues` for the network. The payload falls back to `dummy0` and
skips the disk test. The console is unaffected: its ring page comes from a fixed
parameter, not from a grant.

Two gaps, one on each side, both filled in 2026-09-22 as **experiments**:

- **Xen:** `xenmem_add_to_physmap_one()` (`xen/arch/riscv/mm.c`) has no
  `XENMAPSPACE_grant_table` case and returns `-ENOSYS`. Copying ARM's case (call
  `gnttab_map_frame()`, then drop the page reference it took) is enough for Xen to grow the
  guest's grant table: `Expanding d1 grant table from 1 to 2 frames`.
- **Guest:** in `baptleduc/linux-xen-riscv`, `arch_gnttab_init()`
  (`arch/riscv/xen/grant-table.c`) returns `-ENOSYS` where ARM's returns 0, so
  `gnttab_init()` stops before it maps the shared frames and `enlighten.c` ignores the
  error. With only the Xen change, the guest oopses writing through a NULL grant-table base
  (fault address `0x2`, the `domid` field of entry 0). Returning 0, as ARM does, fixes that.
  (`arch_gnttab_map_shared()` is also `-ENOSYS`, but so is ARM's, and a PVH guest never calls
  it.)

With both: `SUMMARY: docker=ok k3s=ok disk=ok`, `/dev/xvda` passes a raw and an ext4
write/read-back, the guest uses a real `eth0`, and dom0 pings the guest over `xenbr0` 10 of
10 (four runs on a fast Linux host, QEMU TCG). The diffs are small and are not proposed
fixes; they belong to the people whose code they touch. Ask for them if you want to
reproduce this.

### Host speed decides K3s

With that config, K3s passed under Xen six times out of six on a native Linux host with an
AMD Ryzen 5 230: kubeconfig after 15-18 s, node Ready after 49-77 s, the test pod done
after 45-62 s, no restart. Two of those runs used a Xen and a guest kernel carrying debug
instruments; the other four (2026-09-21 night) used builds with the instruments removed,
keeping only the sstc workaround and the event-channel experiment. On
an i9-12900H laptop under WSL2 the same image ran about 3x slower. There, K3s once exited
on its own startup deadline (`failed to create crd ... context canceled`) and once reached
node Ready after 339 s, after which the server exited during the pod wait, once with
status 0 and no error and once on the same CRD startup deadline; the restarts did not
rescue it and the test pod never finished. Under TCG this stack sits close to K3s's internal deadlines, so run
it on a fast, otherwise idle, native Linux host.

### Read the log by occurrence

dom0 prints the same lines the guest does, about four minutes earlier:
`Kernel command line:`, `Freeing unused kernel image`, `Xen: initializing cpu0`, the
sstc line. **The guest's is the second occurrence.** The initmem size also tells them
apart. A monitor that greps for a guest milestone will fire on dom0 first.

### `dom0_mem` goes on Xen's command line, not dom0's

Read this one first. It costs nothing to get right and it is invisible when you get it
wrong.

Xen and dom0 have separate command lines, and `generate_dtb.sh` builds both:
`PLATFORM_XEN_BOOTARGS` becomes Xen's, `DOM0_BOOTARGS` becomes the dom0 Linux kernel's.
In the recipe as it stands, `dom0_mem=512M` is in `DOM0_BOOTARGS`. That is the wrong
one. `dom0_mem` is registered with `custom_param("dom0_mem", parse_dom0_mem)` at
`xen/arch/riscv/domain_build.c:59`, and `custom_param` registers a **Xen** option.
Linux has no parameter of that name.

What Linux does with it is what it does with any unrecognised `key=value`: hands it to
userspace as an environment variable. That is the tell, and it is in the boot log:

```
Run /sbin/init as init process
  with arguments:    /sbin/init bootmem_debug
  with environment:  HOME=/  TERM=linux  dom0_mem=768M
```

If you see `dom0_mem` in init's environment, it was never parsed by anything. The
corroborating numbers, from the same boot with `dom0_mem=768M` set:

```
Built 1 zonelists, mobility grouping on.  Total pages: 131136
Memory: 246060K/524544K available (...)
```

131136 x 4096 = 512 MiB exactly — the default. Setting it to 896M or 1536M changes
nothing; dom0 gets 512 MiB every time.

The contrast makes it unmistakable: `dom0_max_vcpus` is declared four lines earlier in
the same file, `integer_param("dom0_max_vcpus", ...)` at `domain_build.c:23`, and if
you put that on `PLATFORM_XEN_BOOTARGS` it works. Same file, same kind of parameter.

The fix:

```
PLATFORM_XEN_BOOTARGS="com1=poll sched=null dom0_max_vcpus=1 dom0_mem=1536M"
DOM0_BOOTARGS="rw root=/dev/ram console=hvc0 keep_bootcon bootmem_debug debug"
```

**How you will notice, if you notice at all.** With a small dom0 ramdisk, 512 MiB is
enough and nothing is wrong. Grow the image — say, to carry a larger guest payload —
and dom0 OOMs while populating its rootfs (`do_populate_rootfs` → `xwrite`, "System is
deadlocked on memory"). The natural response is to raise `dom0_mem`, which does
nothing, and you are then debugging a memory problem with a knob that is not
connected. Check Xen's own `Command line:` log line against the
`CMDLINE[<dom0 kernel address>]:` line before you touch any value.

### dom0's ramdisk is resident three times, not twice

Related, and it is why the ceiling arrives sooner than arithmetic suggests.

When the initrd is not a cpio archive — an ext2 image, as here —
`do_populate_rootfs` calls `xwrite` to write the **whole image** into the rootfs tmpfs
as `/initrd.image`, and only then does `rd_load_image` copy it from there into
`/dev/ram0`. So the peak is:

```
image size in the rootfs tmpfs (as /initrd.image)
+ image size in brd
+ dom0 kernel and userland
```

against a tmpfs capped at half of dom0's RAM. For a 244 MiB image that is about
500 MiB of copies alone, which does not fit in the 512 MiB dom0 gets by default —
and at 214 MiB it does, which is why a working setup breaks when the image grows.

Size `dom0_mem` against three copies, not two. This model is read from an OOM stack
trace rather than sampled, so treat the multiplier as sound and the exact peak as
approximate.

### Your build image cannot build your own tools

Two independent defects, both in `automation/build/debian/trixie-riscv64`, and fixing
only the first turns one error into another.

**`libfdt-dev:riscv64` is not in the DEPS list.** The Dockerfile installs
`device-tree-compiler`, which is the host amd64 `dtc` binary, not the riscv64 libfdt
headers. Since commit `9a9840b`, "tools/libxl: enable libfdt for RISC-V builds",
`tools/libs/light` needs them:

```
libxl_libfdt_compat.c:60:10: fatal error: libfdt.h: No such file or directory
make[7]: *** [.../Rules.mk:188: libxl_libfdt_compat.o] Error 1
```

**The committed `config_tools.status` knows nothing about fdt.** `TOOLS_CONFIG` copies
it over the tree's own and runs `bash ./config.status`, which re-substitutes cached
results and never re-probes. The file has no `-lfdt` in `LIBS` and none of
`HAVE_LIBFDT`, `HAVE_DECL_FDT_PROPERTY_U32`, `HAVE_FDT_FIRST_SUBNODE`,
`HAVE_FDT_NEXT_SUBNODE`, `ENABLE_PARTIAL_DEVICE_TREE`. With
`HAVE_DECL_FDT_PROPERTY_U32` undefined, `libxl_libfdt_compat.h:75` defines its own
`static inline fdt_property_u32`, which collides with the real one once libfdt is
installed:

```
libxl_libfdt_compat.h:75:19: error: redefinition of 'fdt_property_u32'
```

`git log -- .../config_tools.status` returns exactly one commit, `9a9840b` itself, so
the cached config was committed alongside the change that invalidated it.
`tools/configure:9178` carries the patched `arm*|aarch64|riscv*)` case, so the script
is right and only the cached output is stale. Rerunning configure with the invocation
recorded in the file's own `ac_cs_config` (`--host=riscv64-linux-gnu`) makes all five
probes pass. `qemu_xen` stays `n` afterwards, so this does not drag in a QEMU
submodule build.

### `make dist` silently produces a toolstack with no `xl` in it

This one goes green, which is why it is worth reading carefully.

`config/Tools.mk` line 1 is `-include $(XEN_ROOT)/config/Paths.mk`. The leading dash
silences a missing file, so when `Paths.mk` does not exist, `bindir`, `sbindir` and
`libdir` expand to empty and every tools install flattens into `dist/install/`.
`Paths.mk` is generated by the **top-level** `config.status`, which the Makefile runs
in `XEN_CONFIG`, used by `dist-xen` — but the rule is `dist: dist-tools dist-xen`, so
the tools install always runs first with the variables empty. Timestamps on a real
build: `config/Tools.mk` at 16:37:52, `config/Paths.mk` 59 seconds later.

The flattening then collides two installs on one path:

```
cross-install -m0755 -p xl              .../dist/install        (1 028 944 B binary)
cross-install -m0644 -p bash-completion .../dist/install/xl      (393 B script)
```

The second overwrites the first. `dist/install/xl` ends up being the bash-completion
snippet, beginning `# Copy this file to /etc/bash_completion.d/xl`. There is no `xl`
program in the tree at all, and `make dist` exits 0.

Making `TOOLS_CONFIG` run `$(XEN_CONFIG)` first fixes it. Afterwards
`dist/install/usr/local/sbin/xl` is a 1 028 944-byte riscv64 ELF and the completion
script is at `etc/bash_completion.d/xl`. Note `xl` installs to **sbin**, not bin.

The `Makefile` lines referring to `dist/install/usr/local/lib` and
`.../sbin/xenstored` are **correct as written** — the temptation on seeing the flat
layout is to change them to match, which bakes the bug in and hides the missing
binary permanently.

### The initrd library list is not a dependency closure

The Dockerfile copies a hardcoded list of six riscv64 libraries into
`${INITRD_DIR}/lib`. That list has never been complete. A `readelf -d` scan over all
77 ELF files in the staged tree, unioning 25 distinct `DT_NEEDED` sonames, finds three
missing:

| soname | required by |
|---|---|
| `libfdt.so.1` | `libxenlight.so.4.18.0` |
| `libm.so.6` | `xentop` |
| `libtinfo.so.6` | `libncurses.so.6` and `xentop` |

`libfdt.so.1` is a consequence of enabling libfdt. `libtinfo.so.6` is not: the list
has always copied `libncurses.so.6`, which needs it, and that was broken for `xentop`
long before anyone touched libfdt. It was invisible only because the build died
earlier.

**The transitive case is the one that bites.** `xl`'s own `DT_NEEDED` never mentions
libfdt — it lists `libxlutil`, `libxenlight`, `libxentoollog`, `libyajl`, `libc`. It
is `libxenlight.so.4.18.0` that needs `libfdt.so.1`, and the loader resolves
transitively before `main` runs. So `xl create` dies naming a library `xl` does not
declare, and checking `xl`'s own metadata sends you to the wrong place.

If you automate this, note that a check at Docker-image build time is not enough: at
that point `${INITRD_DIR}` holds about ten files and `libxenlight` does not exist yet,
because the tools are compiled later against a mounted tree. Such a check reports
"all resolved" and passes. It needs a second call site just before `genext2fs`.

### A busybox dom0 can attach a `vif`, but not out of the box

**libxl execs the hotplug script itself; there is no udev involved.**
`xen/tools/hotplug/Linux/` has no `*.rules` and its Makefile never mentions udev. The
path is `device_hotplug()` at `libxl_device.c:1185` →
`libxl__get_hotplug_script_info()` at `libxl_linux.c:201` →
`libxl__async_exec_start()`, with argv `{script, "online", "type_if=vif"}` built at
`libxl_linux.c:145-151`. So a minimal dom0 with no udev and no systemd is fine in
principle.

Four things in the stock image stop it in practice, and three of them fail silently:

1. **The scripts are `#!/bin/bash` and there is no bash.** Rewriting the shebang does
   not help: `>&/dev/null`, `trap ... ERR`, `[[ ]]`, arrays and fd 200 in
   `locking.sh` are all on paths that always run. A riscv64 bash has to go in. It
   needs `libtinfo.so.6`, which is one of the three missing libraries above.
2. **`/var/log/xen` does not exist** and `xen-hotplug-common.sh:23` appends stderr
   there. A failed `exec` redirect kills the shell immediately.
3. **The xenstore binaries are not on the scripts' PATH.**
   `xen-hotplug-common.sh:25` adds `/usr/local/bin`; they are at
   `/dist/install/usr/local/bin`. Symlinking `/usr/local/{bin,sbin}` works. Symlink
   `/usr/local/lib` to `/lib`, **not** to the dist path, because `initrd-tools` moves
   `dist/install/usr/local/lib/*` into `/lib`; that also makes
   `hotplugpath.sh`'s `LIBEXEC_BIN=/usr/local/lib/xen/bin` resolve.
4. **`/etc/xen/scripts` does not exist**, while libxl's compiled-in `XEN_SCRIPT_DIR`
   is exactly that (`tools/config.h:155`). The image's `/etc/xen` holds only
   `xl.conf`.

`ip`, `brctl` (`addbr`, `addif`, `stp`, `setfd`), `ip addr flush` and
`ip link set ... master` are all in busybox. `iptables` is not, which is benign —
`vif-common.sh:189` returns early — but it means no anti-spoof filtering.

Worth proving before you boot: `bash -n` over every script you install, and then
actually run `vif-bridge online type_if=vif` with a synthetic environment. The pass
condition is that it gets past the `exec 2>>/var/log/xen/xen-hotplug.log` line and
that any `xenstore-write` failure is a *connect* error rather than `command not
found` — those two look similar in a log and mean entirely different things.

The likely failure mode if you skip this is `xl create` timing out on
`hotplug-status` with nothing in any log.

### dom0 cannot have virtio devices

Do not plan on giving dom0 a virtio NIC or a virtio disk and bridging from there.
`generate_dtb.sh` deletes every virtio and pci node from the dom0 device tree, with
the comment "Virtio and PCI isn't supported now", and `handle_device()` in
`xen/arch/riscv/domain_build.c` is a `printk` stub that maps no MMIO and routes no
IRQ. riscv's Kconfig does not select `HAS_PCI`, so MMIO would be the right form if
this is implemented later. Adding `-netdev` to the QEMU line does nothing, and the
failure looks like a networking problem rather than a missing device.

That leaves an isolated bridge with no uplink for a first attempt: `xenbr0` in dom0
with a static address, the guest static on the same subnet, and the guest's disk
backed by a file in dom0. No internet, which is fine, because the payload's images
come from tarballs in the initrd anyway.

### `xen_defconfig` compiles no PV backends

The one that explains a lot:

| symbol | `xen_defconfig` |
|---|---|
| `XEN_BACKEND` | `y` |
| `XEN_NETDEV_BACKEND` | **`n`** |
| `XEN_BLKDEV_BACKEND` | **`n`** |
| `XEN_NETDEV_FRONTEND` | `y` |
| `XEN_BLKDEV_FRONTEND` | `y` |
| `BRIDGE` | `m` |
| `TUN` | `n` |

`XEN_BACKEND=y` is the xenbus backend infrastructure. Neither driver that actually
serves a device to a guest is built, so a dom0 from this config can present no PV
network and no PV disk whatever else works. `BRIDGE=m` is the same as absent in a
module-less initrd, per the earlier section.

A dom0 fragment that fixes it, merged the same way as `container.config`:

```
CONFIG_XEN_NETDEV_BACKEND=y
CONFIG_XEN_BLKDEV_BACKEND=y
CONFIG_BRIDGE=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_LLC=y
CONFIG_STP=y
CONFIG_TUN=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_BLK_DEV_LOOP_MIN_COUNT=8
CONFIG_EXT4_FS=y
```

`xen-netback.ko` and `xen-blkback.ko` then appear in `modules.builtin`, with 107
matching symbols in `System.map`.

**This has not been shown to be sufficient**, only necessary. The backends lean on
grant tables and event channels considerably harder than the frontends do, and nobody
has yet run a guest against them on this port.

### `xl info` works, and one line in it will stop `xl create`

With the three libraries added, `xl` runs and talks to the hypervisor:
`virt_caps : hvm hap gnttab-v1`, `xen_caps : xen-3.0-riscv64`, `xen_scheduler : null`.

The line to read before trying to create a guest is **`free_cpus`**. `sched=null` is a
strict 1:1 pinning scheduler: every vCPU needs its own physical CPU. With `-smp 1`,
dom0 has the only one and `free_cpus` reads 0, so a guest cannot be created. Raise
`-smp`, raise `PLATFORM_PCPU_NUM` in `generate_dtb.sh` to match, and add
`dom0_max_vcpus=1` to the Xen bootargs so dom0 takes one and the rest stay free.
`dom0_max_vcpus` is supported on this port (`xen/arch/riscv/domain_build.c:23`).

One unexplained observation: after moving to `-smp 4` with `dom0_max_vcpus=1`, a dom0
console stalled part-way through echoing a command and produced nothing further.
Three idle physical CPUs spinning under TCG is a plausible cause and was never
confirmed. If you see it, try `-smp 2` before concluding anything about Xen.

### Two config files are baked into images and silently shadow the copy you edit

- `domu.cfg` is copied into the dom0 ext2 image at build time by `create-tools-dirs`.
  Editing it afterwards changes nothing; the image has to be rebuilt. **The file on
  disk being right is never evidence that the image is right.** Read it back out with
  `debugfs -R "cat /domu/domu.cfg"` — its size is a useful tell.
- `generate_dtb.sh` is baked into the container image at `/build/dtb/generate_dtb.sh`
  by the Dockerfile, and `$(DTB_SCRIPT)` points at that copy. Edits on disk are not
  seen unless you mount over it:
  `-v /path/to/generate_dtb.sh:/build/dtb/generate_dtb.sh:ro`.

Both fail quietly, with the old value used and no warning. This cost time on four
separate occasions.

### `-m` and `PLATFORM_RAM_SIZE` must move together

The machine size lives in the Makefile's QEMU flags and again in `generate_dtb.sh`,
where it drives the `dumpdtb` run that produces the DTB's memory node. Change one and
the guest is handed a device tree describing a different machine than QEMU created.
Because of the previous point, it is easy to change one and believe you changed both.
The same applies to `-smp` and `PLATFORM_PCPU_NUM`.

### `root=/dev/ram` has a hard ceiling of its own

Separate from the memory question above. `rd_load_image()` compares the image size
against the `/dev/ram` capacity, which comes from `CONFIG_BLK_DEV_RAM_SIZE` — 262144
KiB, 256 MiB, in these configs. Over that, dom0 gets no root and the only clue is a
single `RAMDISK: image too big!` line. The escape is the `ramdisk_size=` boot
parameter in KiB (`drivers/block/brd.c` declares `rd_size` with
`__setup("ramdisk_size=", ...)`), not a rebuild, and this one **is** a Linux
parameter, so it does belong on `DOM0_BOOTARGS`. `dom0_mem` need not cover
`ramdisk_size`, because `brd` allocates a page only when one is written.

### Do not copy the Xen static archives into the ramdisk

`dist` is about 122 MiB, of which about 99 MiB is 15 `*.a` files that nothing links
against at run time. Excluding them takes the dist contribution to roughly 23 MiB.
Use `tar --exclude='*.a'` rather than `cp -r` plus a delete: the nine `xenstore-*`
binaries are a single hardlink group and `cp -r` expands them into nine full copies.

### The guest's disk must not live in dom0's ramdisk

dom0 boots `root=/dev/ram`, so **the ramdisk is the ext2 filesystem**. A disk image
created there at run time spends that filesystem's free blocks, not some separate
pool. On a 244 MiB image with 9.6 MiB free:

```
dd if=/dev/zero of=/domu/disk.img bs=1M count=64
9+0 records out
10067968 bytes (10 MB, 9.6 MiB) copied
```

**`dd` exits 0.** The backend then attaches a 9.6 MiB disk, and a disk test that
writes a megabyte and a small file will pass on it.

Use a tmpfs instead, which costs dom0 RAM out of `dom0_mem` and touches neither the
filesystem nor the `brd` ceiling:

```
mount -t tmpfs -o size=96m tmpfs /mnt
dd if=/dev/zero of=/mnt/disk.img bs=1M count=64     # 64+0 records out
```

Check the **record count**, not the exit status. And make sure the mount point exists
and is empty: mounting over a non-empty directory succeeds while hiding what was
underneath.

Two margins are easy to conflate here and they are different numbers: free space
*inside* the filesystem, and headroom from image size to the `brd` cap. The second is
past the end of the filesystem and unreachable without `resize2fs`.

### `vif` and `disk` syntax

Checked against this tree's own parsers — vif keys from `xen/tools/xl/xl_parse.c:418`
onward, disk keys from the lexer `xen/tools/libs/util/libxlu_disk_l.l`:

```python
vif  = [ 'type=vif,mac=00:16:3e:00:00:01,bridge=xenbr0,script=/etc/xen/scripts/vif-bridge' ]
disk = [ 'format=raw,vdev=xvda,access=rw,backendtype=phy,target=/mnt/disk.img' ]
```

`backendtype=phy` against a plain **file** is legal: `disk_try_backend()` for PHY
requires format raw and calls `libxl__try_phy_backend()`, which on Linux returns 1 for
`S_ISBLK || S_ISREG`, and the `block` script then `losetup`s it. Do **not** use
`backendtype=qdisk` — that needs a device-model process and there is no QEMU in this
dom0.

### The guest will report `driver vif`, not `xen-netfront`

If you log which driver is behind the guest's interface, expect `vif`.
`xenbus_probe.c:376` does
`drv->driver.name = drv->name ? drv->name : drv->ids[0].devicetype`, neither frontend
sets `.name`, and the id tables are `netfront_ids[] = { "vif" }` and
`blkfront_ids[] = { "vbd" }`. Grepping a guest console for `xen-netfront` finds
nothing on a boot where netfront worked.

### dom0 gets no RTC

`goldfish_rtc 101000.rtc: error -ENXIO: IRQ index 0 not found` under `-M virt` with
this tooling. Worth knowing because K3s issues its own certificates with
`NotBefore=now`; the payload already handles the guest case by setting the clock to
its build date if it finds itself earlier. Whether a domU is presented with a clock at
all is still untested.

## What has not been tested

- **K3s under Xen has passed six times on one host** (see "Host speed decides K3s");
  on a slower host it is marginal. All results outside the dom0/domU section are from
  plain `-M virt` with no hypervisor.
- **The domU that boots needs an experimental guest-kernel change** for the event-channel
  interrupt (above). No domU has booted on an unmodified guest kernel past that point.
- **Nothing on riscv64 hardware.** All boots were TCG on x86_64.
- **Two domUs need a third experimental change, in Xen.** A frame large enough to be
  grant-mapped between two guests reaches `page_get_owner_and_reference()`, an
  `assert_failed()` stub in `xen/arch/riscv/mm.c`, and the hypervisor stops. See "Two domUs,
  one cluster". With ARM's one-line definition of that wrapper in place, two guests ping each
  other 5/5 and the two-node K3s test passes; without it, the first ping asserts.
- **Two-node K3s is 3/3 with both guests confirming, on one host, under TCG.** That is a
  result, not a stability claim, and TCG timing says nothing about hardware timing.
- **One vCPU per guest.** Everything here runs `sched=null` with a single vCPU per domain.
- **No guest state survives a restart.** A domU can be powered off but not destroyed or
  rebooted on riscv (`domain_relinquish_resources()` returns `-ENOSYS`), and the powered-off
  domain stays in `xl list`. Nothing here has tested persistence across a guest restart.
- **netfront and blkfront work only with two experimental grant-table changes**, one in
  Xen and one in the guest kernel (see "PV network and PV disk need two grant-table
  changes"). Without them, neither frontend can share its ring. See
  "PV network and PV disk need two grant-table changes". The network and disk results here are
  virtio: a `virtio_net` interface and a `/dev/vda` virtio-blk device. What is proven
  is that the payload handles a real interface and a real block device, not that the
  PV path works.
- **Enabling the PV backends has not been shown to be sufficient.** That
  `xen_defconfig` compiles none is measured; that this is the whole reason there has
  never been PV networking on this port is inference.
- **Both hotplug scripts have run under a real libxl.** `vif-bridge` bridged `vif1.0`;
  `block add` completed once `/dev/stdin` existed.
- **The `dom0_mem` fix is unconfirmed.** Moving it to Xen's command line is correct by
  construction, but no boot has yet both reached a shell and reported more than 512
  MiB of dom0 memory, so whether it resolves the OOM is open.
- **The three-copy memory model is read from an OOM stack trace**, not sampled.
- **The floors were measured on a 7.2.6 payload kernel**, not on a 6.18 Xen guest
  kernel. One 6.18 boot at `-m 1152` with the `k3s` variant passed, and the cap model
  predicted it to within 1 MiB, but no floor has been re-bisected. They were not
  re-bisected after `hello-world` and the disk test were added either: that change
  costs under 33 KB unpacked per variant against a table whose steps are 32 to 64 MiB,
  so both recommended sizes were simply re-run. Checked by proxy, not measured.
- **The `.zst` archives' `.sha256` sidecars, and the `.gz` ones, are malformed.** They
  read `<hash>  -` rather than `<hash>  <filename>`, because the build passes the name
  through an `awk` variable that awk resets when reading stdin. The hashes are
  correct; `sha256sum -c` on one will read stdin instead of the file.
- **The `.zst` archives have never been booted.**
- **`initrd-full.cpio.gz` has only been booted with `test=docker` and `test=k3s`**,
  never with `k3s.full=1` end to end.
- **`earlycon=sbi` under Xen** was what made the pre-console hang visible; measured, but
  only on this one configuration.

## Files

| path | what |
|---|---|
| `kernel/container.config` | the 143-symbol fragment |
| `kernel/check-fragment.py` | verifies every symbol survived the merge |
| `kernel/NOTES.md` | how the test kernel was built, and its config |
| `initrd/NOTES.md` | the authoritative payload notes: floors, guard, contents, build |
| `initrd/init` | the source of what actually runs. Since `k3s.cfgtimeout=` was added only `initrd.cpio.gz` (the `all` variant) has been rebuilt; the `docker`, `k3s` and `full` archives still carry the previous `init`, which has no `k3s.cfgtimeout` |
| `initrd/build.sh` | rebuilds every variant from scratch |
| `validation/harness/` | `run-boot.sh`, `scan.sh`, `analyse.py` |
| `validation/logs/` | console log and meta file for every boot |

`README.md` in this directory predates the split into per-test variants and its RAM
figures and archive sizes are stale. `initrd/NOTES.md` is authoritative.
