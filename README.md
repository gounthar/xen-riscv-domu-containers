> **This file is out of date. `initrd/NOTES.md` is authoritative.**
>
> It was written before the payload was split into four variants and before
> the artifacts were rebuilt on 2026-09-20 for the disk test and the
> real-interface change. Three things in it are wrong:
>
> - The artifact table names `initrd/initrd.cpio.gz` as 213 804 065 bytes.
>   The file that ships is 205 016 731 bytes, so the SHA-256 beside it
>   describes an artifact that no longer exists.
> - It gives a single RAM floor of 1344 MiB. That is the *recommended* size
>   for the `all` variant, not a floor and not universal. The measured
>   floors are 560 (`docker`), 1024 (`k3s`), 1248 (`all`) and 1728 (`full`)
>   MiB; see "RAM: the floor, and why the old numbers were wrong" in
>   `initrd/NOTES.md`.
> - It describes one initrd. There are four: `docker`, `k3s`, `all`, `full`.
> - It says nothing has run under Xen. Since 2026-09-21 the payload has: a domU
>   started through dom0 and `xl create`, under QEMU TCG, runs Docker and K3s
>   (`SUMMARY: docker=ok k3s=ok`, six of six runs on a fast Linux host), with a
>   Xen guest kernel from `baptleduc/linux-xen-riscv`, not the kernel described
>   below. PV network and PV disk work too, but only with two experimental
>   grant-table changes. Nothing on hardware. See `REPLICATION.md`,
>   "Notes for the dom0 and domU path".
>
> - It does not know `test=identity` (added 2026-09-23 as a row in the table
>   below), which probes node identity and disk names instead of running a
>   test. On a riscv64 Xen domU it found no DMI table and the domain UUID at
>   `/sys/hypervisor/uuid` (run 67, TCG).
>
> Kept rather than deleted because the prose around those numbers is still
> accurate and `REPLICATION.md` links into it.

# riscv64 container test payload

A kernel and an initrd that boot straight into two tests, print greppable
markers on the serial console, and power off:

* a Docker container run, with a seccomp filter applied,
* a single-node K3s cluster running one pod.

The eventual target is a **Xen dom0less domU on RISC-V**. A dom0less domU is
started by the hypervisor at boot with no dom0 behind it, so there is no
backend domain to provide PV devices: no PV network, no PV disk. The payload is
built for exactly that shape. The whole root filesystem is an initrd living in
RAM, nothing is mounted from a disk, and the only network is a `dummy0`
interface with a static address, which exists because K3s refuses to start
without a default route.

**Nothing here has been run under Xen.** *[Out of date since 2026-09-21; see the
banner at the top.]* Everything was developed and verified
on plain `qemu-system-riscv64 -M virt`, under TCG emulation on an x86_64 host.
See "Not tested" at the end, which is the section to read before drawing any
conclusion about Xen.

Every claim below is marked with where it comes from: **[measured here]** for
something reproduced in `validation/`, **[from NOTES]** for a figure taken from
`kernel/NOTES.md` or `initrd/NOTES.md` and not re-measured, **[kernel source]**
for something read out of the Linux 7.2.6 tree.

## Layout

| Directory | What is in it |
| --- | --- |
| `kernel/` | Linux 7.2.6 for riscv64: `Image`, `Image.gz`, the `container.config` Kconfig fragment, the full `config-7.2.6`, the moby and k3s config-checker outputs, the build script and `NOTES.md`. |
| `initrd/` | The payload: `initrd.cpio.gz` (and a full variant, and zstd versions), the `/init` source, `build.sh` that rebuilds it, `NOTES.md`, and the builder's own boot log. |
| `validation/` | An independent re-run of the artifacts as shipped: console logs, the harness that produced them, the checksums, and a negative control. |

## Booting it

`qemu-system-riscv64` is not installed on the WSL2 host used here, so QEMU runs
in a container. Everything below was run with QEMU 10.0.13, the Debian trixie
package. No other version was tried.

```bash
qemu-system-riscv64 -M virt -m 2048 -smp 4 -nographic -no-reboot -nic none \
  -kernel kernel/Image \
  -initrd initrd/initrd.cpio.gz \
  -append "console=ttyS0 test=all k3s.timeout=5400 k3s.podtimeout=2400 progress=120"
```

In a container, which is how every log in `validation/` was produced:

```bash
docker build -t xen-domu-qemu - <<'EOF'
FROM debian:trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-misc opensbi && rm -rf /var/lib/apt/lists/*
EOF

docker run --rm -i -v "$PWD:/work:ro" xen-domu-qemu \
  qemu-system-riscv64 -M virt -m 2048 -smp 4 -nographic -no-reboot -nic none \
    -kernel /work/kernel/Image -initrd /work/initrd/initrd.cpio.gz \
    -append "console=ttyS0 test=all k3s.timeout=5400 k3s.podtimeout=2400 progress=120"
```

`-no-reboot` matters: the payload powers off when it is done, and without it
QEMU would restart the guest instead of exiting. `-nic none` is deliberate, to
match a domU with no PV network. **Do not go below `-m 1344`**: the initrd stops
unpacking completely and the failure is not obvious. See "Measured RAM floors".

A pass looks like this on the console, and QEMU exits 0:

```
PAYLOAD_START
DOCKER_OK
K3S_OK
SUMMARY: docker=ok k3s=ok
PAYLOAD_DONE
[  295.406719] reboot: Power down
```

Failures print `DOCKER_FAIL: <reason>` or `K3S_FAIL: <reason>` instead, followed
by the tail of the relevant daemon log, and `SUMMARY:` records which test failed.
When grepping, anchor the pattern to the whole line: a failure message quotes
what the container actually printed, so a bare substring search can match the
word `DOCKER_OK` inside a `DOCKER_FAIL` line.

### Kernel command line

Read out of `initrd/init`, function `parse_cmdline`. Everything is `key=value`
on the kernel command line.

| Option | Default | What it does |
| --- | --- | --- |
| `test=all\|docker\|k3s` | `all` | Which tests to run. `all` runs Docker first, then prunes the Docker stack and runs K3s. |
| `test=identity` | | Run no test. Print DMI, the device tree, `/sys/hypervisor`, `/etc/machine-id` and the block device names between `IDENTITY_START` and `IDENTITY_END`, then power off. Branch `feat/identity-probe`; see `REPLICATION.md`, "Node identity and disk name". |
| `debug=1` | off | Do not power off at the end; drop to a login shell on the console. Also implies `keep=1`. |
| `keep=1` | off | Do not delete the unused stack between tests. Costs RAM, useful when poking around afterwards. |
| `k3s.full=1` | off | Do not pass `--disable traefik,servicelb,metrics-server` to the K3s server. Only meaningful with `initrd-full.cpio.gz`, which carries those images; `/init` warns if they are missing. |
| `k3s.timeout=SECONDS` | `1800` | Budget for the node to reach `Ready`. |
| `k3s.podtimeout=SECONDS` | `900` | Budget for the test pod to finish. |
| `docker.timeout=SECONDS` | `600` | Budget for the Docker container run. |
| `docker.storage=NAME` | `auto` | Force a storage driver instead of probing whether overlayfs works on the tmpfs root. |
| `root.size=SIZE` | `90%` | Size of the tmpfs that becomes the real root. Accepts anything `mount -o size=` accepts. |
| `net.addr=CIDR` | `10.0.2.15/24` | Address put on `dummy0`. |
| `net.gw=IP` | `10.0.2.2` | Gateway for the default route. |
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
| `progress=SECONDS` | `30` | How often to print a progress line while waiting. |
| `loglevel=N` or `quiet` | not set | If either is present, `/init` leaves the kernel log level alone. Otherwise it runs `dmesg -n 4` so kernel noise does not drown the markers. This one is not in `/init`'s own header comment, only in the code. |

`console=ttyS0` is not optional on `-M virt`: this kernel's console is the 8250
UART and nothing else is enabled [from NOTES, `kernel/NOTES.md`].

## Artifacts

Sizes and checksums measured here on 2026-09-20 [measured here,
`validation/sha256-measured.txt`].

| File | Bytes | sha256 |
| --- | --- | --- |
| `kernel/Image` | 29 703 168 | `d2cd6a3771a7c4fb159cdf442d72129afdb2c813043bcb54a3c078fae5818d4b` |
| `kernel/Image.gz` | 10 443 578 | `0cf773301de71ac0f779e30afc28aac19157ea232c88e902d44b388c97e12963` |
| `initrd/initrd.cpio.gz` | 213 804 065 | `454e56e87daee58881a6db10572837483227094f35160a82796c0bc293541343` |
| `initrd/initrd.cpio.zst` | 172 657 708 | `7fb2e8bcc7b5fec7e684473ef2c4f4e7eb9773854edc21f055c68d655bc72d40` |
| `initrd/initrd-full.cpio.gz` | 362 104 483 | `b167f6e8332e86c5c607c0ca7447167583f1591db11ddeeb25226b58554c0ddf` |
| `initrd/initrd-full.cpio.zst` | 320 807 670 | `efdaa58442cbe267652d8392a66610e7e40b9d53c93f4572ece4c098853ba91c` |

The two gzip archives have `.sha256` sidecar files and are also listed in
`initrd/NOTES.md`. Both sources agree with the values above. The two zstd
archives and the two kernel images ship with no reference checksum of any kind,
so the values here are a record, not a verification.

Decompressed, `initrd.cpio.gz` is 534 035 456 bytes and `initrd-full.cpio.gz` is
684 268 032 bytes of cpio stream [measured here]. That is what has to fit in RAM
before `/init` starts, and it is what sets the RAM floor below.

The zstd variants need `CONFIG_RD_ZSTD=y`, which this kernel has, but only
`RD_GZIP` is guaranteed on an arbitrary kernel, so the gzip archive is the
default [from NOTES]. The zstd variants were not booted here.

`/init` as shipped next to the archive is byte-identical to the `/init` inside
`initrd.cpio.gz`: both are sha256
`d35f594f1cdd5b14e165fdc57dc6a223d8e680f162886b1bb58a49518286c19b` [measured
here, by extracting the member back out of the archive]. So reading `initrd/init`
tells you what actually runs.

## Measured RAM floors

Short answer, for the boot command above with nothing extra on the command line:

> **Give the domU at least 1344 MiB. 1.5 GiB is the sensible round number.**
> Below 1344 MiB the initrd does not unpack completely, and what happens next
> depends on which files got dropped.

That holds for both tests, and it is not what the payload's own memory figures
suggest. The rest of this section is why.

### The binding constraint is the initramfs tmpfs, not the tests

`CONFIG_TMPFS=y` in `config-7.2.6`, and with no `root=` and no `rootfstype=` on
the command line the kernel makes the initramfs rootfs a **tmpfs** rather than a
ramfs (`init/do_mounts.c`, `init_rootfs()` sets `is_tmpfs`, and
`rootfs_init_fs_context()` then calls `shmem_init_fs_context()`) [kernel source].
A tmpfs mounted with no `size=` option defaults to **half of RAM**. The payload
needs roughly 580 MiB of rootfs, so the image only unpacks in full once half of
guest RAM clears that.

Measured, one boot per row, shipped artifacts, default command line [measured
here, `validation/logs/`]. "Unpacked" is what `free` reports as used at the first
`/init` sample, and "truncated" is whether the kernel printed
`Initramfs unpacking failed: write error`:

| `-m` | guest total | half of it | unpacked | truncated |
| --- | --- | --- | --- | --- |
| 640 | 583 MiB | 291 MiB | 228 MiB | yes |
| 768 | 709 MiB | 354 MiB | 289 MiB | yes |
| 896 | 834 MiB | 417 MiB | 363 MiB | yes |
| 1024 | 960 MiB | 480 MiB | 428 MiB | yes |
| 1280 | 1211 MiB | 605 MiB | 556 MiB | yes |
| 1344 | 1272 MiB | 636 MiB | 580 MiB | no |
| 1408 | 1336 MiB | 668 MiB | 577 MiB | no |
| 1536 | 1462 MiB | 731 MiB | 583 MiB | no |
| 2048 | 1966 MiB | 983 MiB | 622 MiB | no |

The "unpacked" column tracks the "half of it" column exactly while the cap binds,
then stops growing once the whole image fits. 1280 MiB was booted twice and
truncated both times, so the boundary between 1280 and 1344 is reproducible, not
a one-off.

### Floors, per test

| Test | Lowest size that passes on a complete image | Highest size that fails |
| --- | --- | --- |
| `test=k3s` | **1344 MiB** | 1280 MiB, `K3S_FAIL: no k3s binary at /var/lib/rancher/k3s/data/current/bin/k3s` |
| `test=docker` | **1344 MiB** | see below, it has no clean failure boundary |

The asymmetry between the two tests comes straight out of the archive order. The
minimal image has 4068 cpio members; `/var/lib/rancher/k3s/data/...` starts at
member 1961 and runs to the end, and `usr/local/bin/dockerd` is member 1960,
immediately before it [measured here, `cpio -itv` on the shipped archive]. A
truncation therefore takes the K3s tree first and leaves the Docker stack intact.

`test=k3s` fails the moment the image truncates, for exactly that reason. The
failure is clean: a `K3S_FAIL` line naming the missing binary, a `SUMMARY:`,
`PAYLOAD_DONE` and a normal power off. Nothing in that output says the image was
incomplete.

`test=docker` is the trap. It **keeps printing `DOCKER_OK` on a truncated image**
all the way down to 768 MiB [measured here: 1024, 896 and 768 all print
`DOCKER_OK` and `SUMMARY: docker=ok`, and all three logs also contain
`Initramfs unpacking failed`]. It gets away with it because its binaries sit just
before the cut, and because `test=docker` calls `prune_k3s` and deletes the rest
anyway. Those passes are luck, not headroom. Do not read 768 MiB as a Docker
floor. With a complete image, Docker is known good at 1344 MiB and above.

The 640 MiB panic is the same mechanism gone further: `usr/sbin/switch_root` is
member 2089, inside the stretch that truncation eats, so at 640 MiB the payload
loses the one binary stage 1 cannot do without.

### What failure below the floor looks like

Three different shapes, depending on how far below you are.

**Clean test failure (1280 MiB, `test=k3s`)**, indistinguishable from a real bug
unless you look for the kernel line:

```
[    8.7] Initramfs unpacking failed: write error
...
K3S_FAIL: no k3s binary at /var/lib/rancher/k3s/data/current/bin/k3s
SUMMARY: docker=skipped k3s=failed: no k3s binary at ...
PAYLOAD_DONE
```

**Kernel panic (640 MiB)** [`validation/logs/docker-640.log`]:

```
[    8.466875] Initramfs unpacking failed: write error
[    8.762066] Freeing initrd memory: 208792K
...
PAYLOAD_START
[     9.60] stage 1: initramfs rootfs, moving the root to tmpfs (size=90%)
[    16.31] stage 1: switching root
/init: line 232: exec: switch_root: not found
[   16.390578] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00
```

Truncation has reached `switch_root` itself. Note that `PAYLOAD_START` is printed
even here, on an image that is missing a third of its files. Treat
`PAYLOAD_START` as "the kernel reached userspace", not as "the payload is intact".
The kernel then hangs instead of exiting, because there is no `panic=` on the
command line at that point, so QEMU has to be killed; that run's meta file shows
`exit: 137` for that reason and not because QEMU failed.

**OOM kill**, which only appears once the tmpfs cap is lifted and physical memory
becomes the constraint. See below.

In all three cases the line to grep for first is
`Initramfs unpacking failed: write error`.

### Lifting the cap: `initramfs_options=`

`rootflags=` does **not** apply to the initramfs rootfs; it is ignored, and a boot
with `rootflags=size=90%` at 1024 MiB truncates exactly as it does without it
[measured here, `validation/logs/k3s-1024-rootflags.log`]. The kernel parameter
that does reach that mount is `initramfs_options=`
(`fs/namespace.c`, `initramfs_options_setup()`, passed to the `vfs_kern_mount()`
of `rootfs_fs_type`) [kernel source].

It works, and it does not buy as much as it looks like it should:

* `initramfs_options=size=90%` at **1024 MiB**: the image unpacks completely
  (562 MiB, no truncation), K3s starts, the node reaches `Ready` and the test pod
  is applied, and then the kernel OOM-kills `containerd` at 152 s
  [measured here, `validation/logs/k3s-1024-iropts.log`]. That run was stopped by
  hand rather than left to its 40 minute pod timeout, so its meta file shows
  `exit: 137`.
* `initramfs_options=size=90%` at **768 MiB**: still truncates, because 90 % of
  768 MiB is more memory than the machine has once the 204 MiB compressed initrd
  is also resident [measured here, `validation/logs/docker-768-iropts.log`].

So the option is worth knowing about, and it converts a silent truncation into an
honest OOM, but it does not get a K3s domU meaningfully below 1344 MiB.

### Why the payload's own numbers understate this

`initrd/NOTES.md` reports a 976 MiB peak for `test=all` in a 2 GiB machine,
325 MiB for `test=docker` alone, and suggests "1 GiB is probably enough for
`test=docker`". The peaks reconcile: 952 MiB here for `test=all` against their
976 MiB, and 971 to 975 MiB for `test=k3s` [measured here]. The sizing advice
does not, and the reason is that all of those come from the payload's own
`free -m` calls, which first run after `/init` has started. By then the kernel has
already unpacked the image and freed the compressed copy, so the number that
actually sets the floor has come and gone before anything can sample it. Their
325 MiB figure is the highest `free` sample after the K3s tree is pruned; the
same run here reads 622 MiB at stage 1 and still needs 1344 MiB to boot intact.

### Full variant

`initrd-full.cpio.gz` with `test=docker` at 2048 MiB passes on a complete image,
with a peak `free` used of 750 MiB against 622 MiB for the minimal variant
[measured here, `validation/logs/full-docker-2048.log`]. Its floor was not
bisected. It decompresses to 150 MiB more than the minimal variant and the floor
is set by the unpack against a half-of-RAM cap, so expect roughly 300 MiB more,
in the region of 1.6 to 1.7 GiB. That is an extrapolation, not a measurement.

## What was verified here

The three boots asked for, plus a negative control, all on `kernel/Image` and
the shipped `initrd.cpio.gz`, QEMU 10.0.13 under TCG, `-M virt -smp 4`,
2026-09-20 [measured here]. "Guest" is the timestamp on the `reboot: Power down`
line, "host" is wall clock around the QEMU process.

| Boot | Result | Guest | Host wall |
| --- | --- | --- | --- |
| `test=all`, 2048 MiB | `DOCKER_OK`, `K3S_OK`, `SUMMARY: docker=ok k3s=ok`, exit 0 | 295 s | 298 s |
| `test=docker`, 2048 MiB | `DOCKER_OK`, `SUMMARY: docker=ok k3s=skipped`, exit 0 | 83 s | 86 s |
| `test=k3s`, 2048 MiB | `K3S_OK`, `SUMMARY: docker=skipped k3s=ok`, exit 0 | 281 s | 284 s |

Each printed `PAYLOAD_START` once and `PAYLOAD_DONE` once, powered off cleanly,
and QEMU exited 0. These three boots were run concurrently on the same 20-core
host, so the times are upper bounds rather than best cases. `initrd/NOTES.md`
reports 375 s for `test=all` on a busier host and 244 s on a quieter one, which
brackets the 295 s here.

Twenty boots in total were run, all on the shipped artifacts. Every console log
and the QEMU invocation that produced it are in `validation/logs/`:

| Log | What it is for |
| --- | --- |
| `all-2048`, `docker-2048`, `k3s-2048` | The three boots in the table above. |
| `k3s-evidence-2048` | `test=k3s` with `progress=15`, to force the pod's `kubectl` status onto the console. |
| `neg-docker-2048` | The negative control. |
| `full-docker-2048` | `initrd-full.cpio.gz`, `test=docker`. |
| `docker-{640,768,896,1024,1344,1408}` | The Docker RAM ladder. |
| `k3s-{1280,1280-rerun,1344,1408,1536}` | The K3s RAM ladder, 1280 booted twice. |
| `k3s-1024-rootflags` | `rootflags=size=90%`, which turns out to be ignored. |
| `k3s-1024-iropts`, `docker-768-iropts` | `initramfs_options=size=90%`. |

### The markers are gated, not echoed

This was the thing most worth attacking, since a payload that prints its marker
regardless would pass every test above while proving nothing.

Reading `initrd/init`, which is worth reading precisely because the copy inside
the archive is byte-identical to it: the Docker test runs `docker run --rm --network none
busybox:1.37.0 echo DOCKER_OK`, captures the container's stdout into a shell
variable, and compares it with the literal string. `marker DOCKER_OK` is only
reached if the comparison succeeds and, after that, if a second container run
reports `Seccomp: 2` in `/proc/self/status`. The K3s test applies a pod that
runs `echo K3S_OK`, waits for the pod phase to become `Succeeded` rather than
`Failed`, retrieves `kubectl logs`, and compares. `marker K3S_OK` comes after
that.

Two pieces of evidence that the code does what it reads like:

* In every passing log, `DOCKER_OK` appears on its own line **exactly once**,
  even though the container itself also printed that string. The container's
  output was captured, not passed through to the console.
* A negative control: `initrd/init` was copied, one line changed so the
  container prints `NEGATIVE_CONTROL` instead of `DOCKER_OK`, nothing else
  touched, and the modified `/init` was overlaid on the shipped archive by
  concatenating a small cpio. The result [measured here,
  `validation/logs/neg-docker-2048.log`]:

  ```
  DOCKER_FAIL: container run did not print the marker (got: NEGATIVE_CONTROL)
  SUMMARY: docker=failed: container run did not print the marker (got: NEGATIVE_CONTROL) k3s=skipped
  ```

  `DOCKER_OK` does not appear. The diff is in
  `validation/negative-control/init.diff`.

No equivalent negative control was run for `K3S_OK`. Its logic is the same
shape and reads correctly, but that is inspection, not a measurement.

### The container really ran, with seccomp

From `validation/logs/docker-2048.log`; every passing Docker boot has the same
lines at different timestamps [measured here]:

```
[    38.62] docker: runc version 1.4.0 ... libseccomp: 2.6.0
[    45.53] docker: overlayfs works on the tmpfs root, using the default driver
[    65.39] docker: storage driver: overlayfs
Loaded image: busybox:1.37.0
[    79.90] docker: seccomp inside the container:
Seccomp:	2
Seccomp_filters:	1
DOCKER_OK
```

`Seccomp: 2` is `SECCOMP_MODE_FILTER` and `Seccomp_filters: 1` is one attached
filter, both read from `/proc/self/status` **inside** the container, not on the
host. `/init` fails the test if the mode is anything other than 2, so a
`DOCKER_OK` cannot be reached without it. This also means the payload would catch
a `runc` built without seccomp support, which is why `initrd/NOTES.md` says
Debian's Docker packages were deliberately not used.

The seccomp evidence comes from the Docker test only. The K3s test pod is not
checked for a seccomp profile, and Kubernetes leaves pods `unconfined` by default
unless a `seccompProfile` is set, which this pod spec does not set. So a
`K3S_OK` on its own says nothing about seccomp.

### The K3s cluster really came up

From the `test=k3s` console at 2048 MiB [measured here,
`validation/logs/k3s-2048.log`]:

```
[    55.30] k3s: k3s version v1.37.0+k3s1 (bb7cf065)
[   146.83] k3s node Ready: ready after 64s
[   152.58] k3s: domu Ready control-plane 18s v1.37.0+k3s1 10.0.2.15 <none>
            Debian GNU/Linux 13 (trixie) 7.2.6 (riscv64) containerd://2.3.4-k3s1
[   271.74] k3s test pod: ready after 78s
K3S_OK
```

The node line is real `kubectl get nodes -o wide` output, printed verbatim: the
node reached `Ready` with the `dummy0` address as its node IP, running the
riscv64 7.2.6 kernel on `containerd://2.3.4-k3s1`.

The pod's own status does not normally reach the console, because `progress=120`
is longer than the pod takes. A separate boot with `progress=15` forces it out
[measured here, `validation/logs/k3s-evidence-2048.log`]:

```
[   256.06] k3s: | pod: payload-test   0/1   Completed   0     58s
[   271.74] k3s test pod: ready after 78s
K3S_OK
```

That line is `kubectl get pod payload-test`, verbatim. The pod reached
`Completed`, and only then was the marker printed. cgroup v2 came up in every
boot with `cpuset cpu io memory hugetlb pids` available and all of them delegated
to `cgroup.subtree_control`.

### Deviation: K3s is shipped pre-unpacked

Worth knowing, because it means the domU path is not byte-identical to the
hardware smoke test that motivated this.

The K3s release binary is a self-extracting bundle that unpacks about 244 MiB on
first run. `build.sh` unpacks it **at build time**, at the exact path it will run
from, verifies the unpacked tree against the bundle's own `.sha256sums`, and
ships only the unpacked tree. `/init` then runs
`/var/lib/rancher/k3s/data/current/bin/k3s server` directly. The self-extracting
stub is not in the image [read from `initrd/build.sh` and `initrd/NOTES.md`].
The stated reasons are 77 MiB of RAM saved and a 3m50s unpack avoided at every
boot, and that the upstream `rancher/k3s` container image runs K3s the same way.

The version that runs is the intended one: every K3s boot here reports
`k3s version v1.37.0+k3s1 (bb7cf065)` on the console and the node registers as
`v1.37.0+k3s1` [measured here]. So the version matches the hardware smoke test
even though the delivery mechanism does not.

## Build timings

Both parts were **cross-built on x86_64** (WSL2 Debian, 20 cores, 31 GB RAM) in
Docker containers. **No step ran natively on riscv64 hardware.** The riscv64
userland steps in the initrd build ran under qemu-user emulation, which is also
not native. These figures are not comparable to a build on a real board;
cross-building and native riscv64 routinely differ by an order of magnitude.

Kernel [from NOTES, `kernel/NOTES.md`, one run each, timed inside the container]:

| Step | Wall | CPU (user+sys) |
| --- | --- | --- |
| `mrproper` + `merge_config.sh` + `olddefconfig` | 32.4 s | 25.1 s |
| `make -j20 Image Image.gz` | 8 m 22 s | 119 m 01 s |

Initrd [from NOTES, `initrd/NOTES.md`, wall clock]:

| Step | Wall |
| --- | --- |
| download release assets (cached after the first run) | 1 s |
| build the amd64 tools image | 22 s |
| strip binaries, unpack tini | 7 s |
| pull and save the riscv64 images (minimal) | 107 s |
| build the riscv64 rootfs image (apt plus K3s unpack, emulated) | 211 s |
| offline checks (emulated) | 23 s |
| assemble the minimal initrd (cpio, `gzip -9`, `zstd -19`) | 236 to 271 s |
| assemble the full initrd | 293 to 335 s |
| total, `VARIANT=both` | 900 s |

Neither set was re-measured here. The kernel notes state the artifacts shipped
are from the first build, not the timed one, because the kernel embeds a build
counter and a timestamp, so a rebuild of the identical `.config` gives a
different `Image` checksum.

## What is in `validation/`

| Path | What |
| --- | --- |
| `sha256-measured.txt` | The checksums above, as computed. |
| `logs/*.log` | Full console log of every boot run here, one file per boot. |
| `logs/*.meta` | The exact QEMU invocation, the input checksums, the exit code and the wall time for each. |
| `harness/run-boot.sh` | Boots one configuration and writes the log and the meta file. |
| `harness/scan.sh` | Drives `run-boot.sh` down a ladder of `-m` sizes and stops at the first failure. |
| `harness/analyse.py` | Summarises a log: marker counts, peak `free` usage, seccomp, K3s version. It strips the carriage returns the serial console emits, which a naive `grep '^DOCKER_OK$'` will not match. |
| `negative-control/init.diff` | The one-line change used for the negative control above. |

## Not tested

Read this before concluding anything about Xen.

**Nothing has been run under Xen.** No domU boot, no Xen build, no Xen host.
*[Out of date: true when written, overtaken on 2026-09-21; see the banner at the top
and `REPLICATION.md`. What follows about Linux 7.2.6 still holds.]*
Every result in this repository comes from `qemu-system-riscv64 -M virt` with no
hypervisor involved.

**There is no Xen guest support for riscv64 in Linux 7.2.6.** Confirmed by
reading the tree [kernel source, re-checked here against
`linux-7.2.6`, agreeing with `kernel/NOTES.md`]:

* `config XEN` is defined in exactly three places, `arch/x86/xen/Kconfig:6`,
  `arch/arm/Kconfig:1349` and `arch/arm64/Kconfig:1677`. There is no definition
  under `arch/riscv`, so on riscv the symbol does not exist.
* `drivers/xen/Kconfig` opens with `menu "Xen driver support"` / `depends on
  XEN`, and `drivers/Kconfig:156` sources it unconditionally. With no `XEN`
  symbol the entire menu is unreachable, and with it every Xen frontend:
  blkfront, netfront, the PV console.
* There is no `arch/riscv/xen/` directory and no `arch/riscv/include/asm/xen*`
  header.
* `CONFIG_PARAVIRT` does exist for riscv (`arch/riscv/Kconfig:1127`) but it is
  unrelated: it `depends on RISCV_SBI` and implements SBI steal-time accounting.
  arm64 by contrast `select`s `PARAVIRT` from its `XEN` symbol.
* `config-7.2.6` contains no `CONFIG_XEN` line of any kind.

So a stock riscv64 kernel has no grant tables, no xenbus, no event channels, no
PV console, no PV block and no PV net, and there is no Kconfig option to turn
any of it on. Whether this kernel can still boot as a dom0less domU depends
entirely on how much of a plain machine Xen presents to a riscv guest, and on
what console and devices it exposes there. **Only the Xen developer's answer
settles what the guest needs.** Nothing in this repository answers it, and the
most likely outcome is that a stock kernel needs patches.

One specific thing to ask about: this kernel's console is the 8250 UART
(`console=ttyS0`). If a riscv domU is given neither an emulated 8250 nor a Xen
PV console, the kernel would boot and print nothing at all. The tree does have
an SBI console (`CONFIG_HVC_RISCV_SBI`) but it `depends on NONPORTABLE`, which
is not set here, so it is deliberately not enabled and untested [from NOTES,
`kernel/NOTES.md`].

Also not tested:

* **No real network.** There is no network device at all. `/init` creates a
  `dummy0` interface, puts a static address on it and points the default route
  at a gateway that does not exist, purely because K3s refuses to start without
  a default route. Nothing can be reached, nothing can be pulled, and the airgap
  image tars are the only images available. A payload that needed to pull an
  image would fail.
* **Only `-M virt`, only TCG.** Every boot was emulated on x86_64. Nothing ran
  on riscv64 hardware, and nothing ran with KVM. A hardware board and a domU
  both differ from `-M virt` in ways that this cannot predict: a device tree
  written by the hypervisor, memory carved out by it, and no RTC.
* **No RTC handling was exercised against a real domU.** `/init` sets the clock
  to the build date if it finds itself before it, because K3s issues its own
  certificates with `NotBefore=now`. Whether a Xen domU presents a clock at all
  is unknown.
* **The zstd archives were never booted**, here or by their author.
* **The full variant was only booted with `test=docker`.** `k3s.full=1`, the
  path its extra images exist for, has never been run end to end [from NOTES,
  confirmed by the absence of such a log].
* **No negative control for `K3S_OK`.** Only `DOCKER_OK` was falsified
  deliberately.
* **Most command line options were read, not exercised.** `debug=1`, `keep=1`,
  `k3s.full=1`, `docker.storage=`, `root.size=`, `net.addr=`, `net.gw=` and
  `loglevel=` are documented above from `initrd/init`. Only `test=`,
  `progress=`, `k3s.timeout=`, `k3s.podtimeout=` and `docker.timeout=` were
  actually passed to a boot here.
* **The full variant's RAM floor was not bisected**, only extrapolated.
* **The `initramfs_options=` floor was not bisected** either. It is somewhere
  between 768 MiB (still truncates) and 1024 MiB (unpacks, then OOMs under K3s).
* **Build timings were not re-measured**, only copied from the two NOTES files.
* **`Image.gz` was never booted**, only `Image`.
