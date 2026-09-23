# riscv64 container payload initrd: build notes

Part B of the test payload: an initramfs (`cpio.gz`) that boots straight into a
Docker container run, a single-node K3s cluster and a block-device round trip,
entirely from RAM, and prints greppable pass/fail markers on the serial console.
It needs neither a disk nor a network device, and uses both when the guest has
them: the disk test reports `skipped` when there is no device, and the network
falls back to a dummy interface when there is no NIC, so the same image boots
identically on bare `qemu-system-riscv64 -M virt -nic none`.

The eventual target is a Xen dom0less domU on RISC-V. Everything here was
developed and tested on plain `qemu-system-riscv64 -M virt` with no Xen and no
network device, which is what the domU will look like from the guest's side.

Two things changed since the first version of this file, and they are the two
sections to read first if you have read it before:

* **The RAM figures in the old version were wrong**, and wrong in the direction
  that hides a failure. See "RAM: the floor, and why the old numbers were
  wrong". The old file said 1 GiB was probably enough for `test=docker`; the
  real floor for the image it described was 1344 MiB for both tests.
* **The payload now refuses to run on an image the kernel did not unpack in
  full.** See "The truncation guard". That is the failure the old numbers came
  from: a truncated image can still print `DOCKER_OK`.

The image is also split into per-test variants, which is what actually lowers
the floor. See "Artifacts".

## Artifacts

| File | Variant | For |
|---|---|---|
| `initrd-docker.cpio.gz` | `docker` | `test=docker`. Docker engine plus the hello-world and busybox image tars. No K3s. |
| `initrd-k3s.cpio.gz` | `k3s` | `test=k3s`. K3s and its four airgap images. No Docker. |
| `initrd.cpio.gz` | `all` | `test=all`: both stacks in one image, Docker first. |
| `initrd-full.cpio.gz` | `full` | `all` plus traefik, servicelb and metrics-server, for `k3s.full=1`. |
| `initrd-*.cpio.zst` | | the same archives, `zstd -19`, for kernels with `CONFIG_RD_ZSTD=y` |
| `initrd-*.cpio.gz.sha256` | | checksum sidecars |
| `build.sh` | | rebuilds everything from scratch, Docker-based, no sudo |
| `init` | | the `/init` source, copied into every image by `build.sh` |
| `../kernel/Image` | | the kernel every boot here used. It has no Xen support and it is **not** the kernel the domU runs; see "Two kernels, and which is which" |
| `boot-logs/` | | the console log and a `.meta` file for every boot in this document, plus the wrappers that produced them: `run-boot.sh` for a bare guest and `run-boot-dev.sh` for one with a disk or a NIC |

Sizes and checksums, measured 2026-09-20 on the shipped files, rebuilt that
evening for the disk test and the real-interface change. "Unpacked" is
`du -sb` of the staging tree, which is what has to fit in the rootfs tmpfs.

| Variant | unpacked | files | `gzip -9` | `zstd -19` |
|---|---|---|---|---|
| `docker` | 218 356 451 B (208 MiB) | 1154 | 83 363 651 B (80 MiB) | 64 473 980 B (61 MiB) |
| `k3s` | 340 500 287 B (325 MiB) | 1541 | 146 085 780 B (139 MiB) | 119 372 860 B (114 MiB) |
| `all` | 510 099 881 B (486 MiB) | 1548 | 205 016 731 B (196 MiB) | 165 974 905 B (158 MiB) |
| `full` | 660 331 947 B (630 MiB) | 1552 | 353 327 164 B (337 MiB) | 314 142 429 B (300 MiB) |

```
228fe71d1f494143db4cc2386a7c2898386c7c1a0a4abd49b274b7192c402a54  initrd-docker.cpio.gz
e2fd5caae56d359d19a781adaacacf9be9abaf0cdf80f49ffb81332b33e8dee6  initrd-docker.cpio.zst
156b8aec18627b7fd15946de19719b0c292df9f4ea14eee5982264eb52160154  initrd-k3s.cpio.gz
70ef7a726b5725ed033473a35b618ad2c5e44b3817dfa5286c3600b2acf999ea  initrd-k3s.cpio.zst
361eb30f1736468e75f6f5a0b1c308cdd8f66aea56abc095595f9e43f58a711a  initrd.cpio.gz
b5a3ceefc550dfef28ddd6431d58f576aca90005abbd29197f566ef01e42b942  initrd.cpio.zst
da99a1d7a7257b4e685b9ed64070507a2f9cc90c5e414db288fe4972006ade71  initrd-full.cpio.gz
58c44edc05a3c34c28c29b465b209be1bdbb37b793ab3cdcb455bdd225735a70  initrd-full.cpio.zst
```

All four variants were rebuilt again on 2026-09-21 so that every archive
carries the current `init` (`k3s.cfgtimeout=`, fail-fast on a dead K3s server,
`k3s.restarts=`); the `/init` inside each one was checked against `init` here.
The hashes above belong to the 2026-09-20 build. The current ones are in the
`.sha256` sidecars.

Two changes have landed on top of the build described by the RAM tables further
down, and neither moves anything that matters:

| Change | Unpacked cost per variant |
|---|---|
| both tests moved to the `hello-world` image (one 22 016 B tar) | 23 408 to 23 479 B |
| the disk test and the real-interface network change (`/init` only) | 9 226 to 9 276 B |

Together that is under 33 KB, against a floor table whose steps are 32 and
64 MiB. The `.sha256` sidecars beside the archives record the filename as `-`
rather than the archive's name, because of how `build.sh` passes it to `awk`;
the hashes in them are correct, but `sha256sum -c` on a sidecar reads stdin
instead of the file. That predates both changes and is not fixed here.

All four come from one `build.sh` invocation with `SOURCE_DATE_EPOCH=1789893817`,
so they share a build epoch and a Debian package set. The `/init` inside each
archive is byte-identical to the `init` file next to them, sha256
`d5d80f73b046ccbef9bd4a8a74ab4fb8283a9878907c7c95cb3405f29082c866`, checked by
extracting the member back out of all four archives with
`gzip -dc … | cpio -i --to-stdout init | sha256sum`.

zstd is listed for information: it saves 15 to 37 MiB depending on the variant,
and the part A kernel config does have `CONFIG_RD_ZSTD=y`, but only `RD_GZIP` is
guaranteed, so the gzip archive is the default. The zstd archives were not
booted.

### Where the bytes are

Subtracting the variants from each other gives an exact split, because they are
built from one staging tree with parts deleted:

| Part | Bytes | Present in |
|---|---|---|
| Debian base, `/init`, and the hello-world tar | 48 756 857 (46 MiB) | every variant |
| Docker stack plus the busybox tar | 169 599 594 (162 MiB) | `docker`, `all`, `full` |
| K3s tree plus the four K3s airgap tars | 291 743 430 (278 MiB) | `k3s`, `all`, `full` |
| traefik, servicelb, metrics-server, klipper-helm tars | 150 232 066 (143 MiB) | `full` only |

The split is exact to within the manifest, which is itself in the tree and is a
few hundred bytes longer in the variants that name more critical files.

Splitting the image is what buys the RAM, and it buys a lot of it, because the
binding constraint is how much has to be unpacked rather than how much the test
then uses. `test=docker` no longer carries 278 MiB of K3s it deletes on the
first line of the test.

## What the tests run

Both tests run the stock **`hello-world`** image, and both gate their marker on
the text that image prints for itself:

| Test | What runs | What has to appear before the marker |
|---|---|---|
| Disk | raw write and read back of 1 MiB of fresh random bytes on `$DISK_DEV` | the two sha256 sums are equal |
| Disk, second half | mkfs, mount, write a nonce, unmount, remount, read it back | the nonce comes back byte for byte |
| Docker | `docker run --rm --network none hello-world:latest`, no command | `Hello from Docker!` in the captured output |
| Docker, second check | `docker run --rm --network none busybox:1.37.0 grep Seccomp /proc/self/status` | `Seccomp: 2` |
| K3s | a `Never`-pull pod running `hello-world:latest`, no command | `Hello from Docker!` in `kubectl logs` |

No command is passed to `hello-world` in either case, so reaching `DOCKER_OK`
or `K3S_OK` means the image's own entrypoint ran and produced its own text.
The output is printed to the console as evidence and then matched; it is never
echoed as a marker, and it contains no marker string, so a reader cannot
mistake one for the other. On riscv64 the message says so itself, on the line
that reads `(riscv64)`.

**busybox is still in the image, and still needed.** `hello-world` exits
immediately and carries no shell, so the seccomp check, which has to read
`/proc/self/status` from inside a live container, runs busybox. That is the
only thing busybox is used for now.

The hello-world tar is 22 016 B, and it is stored once per variant in the same
`/var/lib/rancher/k3s/agent/images/` directory that K3s imports at agent start.
That is what makes the K3s half an airgap test: with `imagePullPolicy: Never`
and no network device, a pod that runs at all is a pod whose image came out of
that tar.

## RAM: the floor, and why the old numbers were wrong

### What the old version of this file said

> "2 GiB for the domU is comfortable, 1.5 GiB is the sensible floor for the K3s
> test, and `test=docker` alone fits in about 1 GiB." … "the real peak for
> `test=all` was 976 MiB … and a `test=docker`-only boot peaked at 325 MiB used.
> A 1.5 GiB domU should be fine; 1 GiB is probably enough for `test=docker` and
> marginal for K3s."

The peak figures were right. The sizing advice was wrong, in the direction that
hides a failure: the image that file described needed **1344 MiB for both
tests**, and a 1 GiB `test=docker` boot printed `DOCKER_OK` on an image that had
lost a third of its files.

### Why it was wrong

Every number in the old section came from the payload's own `free -m`, and
`/init` cannot run until the kernel has finished unpacking the initrd and freed
the compressed copy. The quantity that sets the floor has come and gone before
anything in userspace can sample it. The 325 MiB figure was worse than that: it
was the highest `free` sample on a boot where the K3s tree had been both
truncated away by the kernel and pruned by `/init`, so it measured a fraction of
the image reporting a fraction of the peak.

### What actually sets the floor

With no `root=` and no `rootfstype=`, the kernel makes the initramfs rootfs a
tmpfs, sized at half the free memory at the moment it is mounted. The compressed
initrd is still resident at that moment, so:

```
rootfs cap  =  (MemTotal - size of the compressed initrd) / 2
```

and the boot only unpacks in full when that cap clears the unpacked size:

```
MemTotal  >=  2 x unpacked size  +  compressed size
```

Measured against every boot below, the cap model is right to within 1 or 2 MiB:

| Boot | MemTotal | compressed | cap predicted | cap measured |
|---|---|---|---|---|
| `docker`, `-m 2048` | 1966 | 79 | 943 | 942 |
| `docker`, `-m 560` | 503 | 79 | 212 | 210 |
| `docker`, `-m 544` | 487 | 79 | 204 | 202 |
| `k3s`, `-m 1024` | 960 | 139 | 410 | 409 |
| `all`, `-m 1280` | 1211 | 196 | 508 | 506 |
| `all`, `-m 1152` | 1085 | 196 | 445 | 443 |
| `full`, `-m 2048` | 1966 | 337 | 815 | 813 |
| `full`, `-m 1536` | 1462 | 337 | 563 | 561 |

This is why shrinking the image pays twice over, and why the **compressed** size
matters too: 2 MiB off the unpacked tree is 4 MiB off the floor, plus whatever
comes off the archive.

`/init` prints that cap, the used figure and the free figure on **every** boot,
on the line straight after `PAYLOAD_START`. From the `docker` variant at
`-m 560`, the lowest size it passes at:

```
PAYLOAD_START
[     4.57] rootfs (initramfs): rootfs 210M total, 209M used, 1M free; MemTotal 503M
```

A boot that fails with 0M free is short of RAM for the unpack. A boot that fails
with room to spare is short of RAM for the test.

### Measured floors

**These floors were bisected on the build of 2026-09-20 10:46 to 12:07, before
both tests moved to `hello-world` and before the disk test existed, and they
were not re-bisected afterwards.** The two changes since add under 33 KB
unpacked per variant, which is 0.07 MiB on `2 x unpacked + compressed` against
a table whose steps are 32 and 64 MiB, so the floors below are carried over
rather than re-measured. Neither floor row itself was re-run; what was re-run
on the shipped files is the **recommended** size for `all`, 1344 MiB, twice,
and both boots pass with the same rootfs figures as before (537M total, 488M
used, 49M free). That is the closest thing here to a direct check that the cap
has not moved.

Bisected on the previous build, QEMU 10.0.13 under TCG on an x86_64
host, `-M virt -smp 4 -nographic -no-reboot -nic none`. A boot counts as a
failure whenever the kernel logged `Initramfs unpacking failed`, whatever else
it printed. Every size in this table was booted at least once, and each passing
floor except `all` at 1248 MiB was booted twice; the full list is below.

| Variant | test | lowest size that passes | highest size that fails | what the failure is |
|---|---|---|---|---|
| `docker` | `test=docker` | **560 MiB** | 544 MiB | unpack: cap 202 MiB against 209 MiB of image |
| `k3s` | `test=k3s` | **1024 MiB** | 960 MiB | OOM during the test; the image unpacks fine from about 896 MiB |
| `all` | `test=all` | **1248 MiB** | 1216 MiB | unpack: cap 474 MiB against 488 MiB of image |
| `full` | `test=k3s` | **1728 MiB** | 1664 MiB | unpack: cap 624 MiB against 631 MiB of image |

Against the old single image at 1344 MiB for both tests, that is **784 MiB less
for the Docker test** and **320 MiB less for the K3s test**.

Round numbers to actually use, with a little headroom, since the passing rows
above are tight (the `docker` variant passes at 560 MiB with 1 MiB of rootfs to
spare, and `k3s` passes at 1024 MiB with 27 MiB of RAM to spare):

> **`initrd-docker.cpio.gz`: 640 MiB. `initrd-k3s.cpio.gz`: 1152 MiB.
> `initrd.cpio.gz` with `test=all`: 1344 MiB. `initrd-full.cpio.gz`:
> 1792 MiB.**

Every boot, in full:

| boot | `-m` | MemTotal | rootfs cap | image | free | truncated | peak used | markers | verdict |
|---|---|---|---|---|---|---|---|---|---|
| `docker-2048` | 2048 | 1966 | 942 | 209 | 732 | no | 298 | DOCKER_OK | **PASS** |
| `docker-640` | 640 | 583 | 250 | 209 | 41 | no | 289 | DOCKER_OK | **PASS** |
| `docker-576` | 576 | 519 | 218 | 209 | 9 | no | 290 | DOCKER_OK | **PASS** |
| `docker-576-rerun` | 576 | 519 | 218 | 209 | 9 | no | 281 | DOCKER_OK | **PASS** |
| `docker-560` | 560 | 503 | 210 | 209 | 1 | no | 288 | DOCKER_OK | **PASS** |
| `docker-544` | 544 | 487 | 202 | 202 | 0 | **yes** | - | - | **FAIL** (guard fired) |
| `docker-512` | 512 | 457 | 187 | 187 | 0 | **yes** | - | - | **FAIL** (guard fired) |
| `docker-448-iropts` | 448 | 393 | 280 | 209 | 70 | no | 242 | - | **FAIL** (dockerd OOM-killed at startup) |
| `docker-448-iropts-run2` | 448 | 393 | 280 | 209 | 70 | no | 289 | DOCKER_OK | **PASS** |
| `docker-448-iropts-run3` | 448 | 393 | 280 | 209 | 70 | no | 292 | DOCKER_OK | **PASS** |
| `docker-448-iropts-run4` | 448 | 393 | 280 | 209 | 70 | no | 285 | DOCKER_OK | **PASS** |
| `docker-384-iropts` | 384 | 332 | 225 | 209 | 15 | no | 238 | - | **FAIL** (DOCKER_FAIL) |
| `docker-testall-1024` | 1024 | 960 | 439 | 209 | 229 | no | 286 | DOCKER_OK | **PASS** |
| `k3s-1024` | 1024 | 960 | 409 | 326 | 83 | no | 933 | K3S_OK | **PASS** |
| `k3s-1024-rerun` | 1024 | 960 | 409 | 326 | 83 | no | 865 | K3S_OK | **PASS** |
| `k3s-960` | 960 | 896 | 377 | 326 | 51 | no | 688 | - | **FAIL** (K3S_FAIL) |
| `k3s-896` | 896 | 834 | 346 | 326 | 20 | no | 697 | - | **FAIL** (OOM, stopped by hand) |
| `all-1280` | 1280 | 1211 | 506 | 488 | 18 | no | 891 | DOCKER_OK,K3S_OK | **PASS** |
| `all-1280-rerun` | 1280 | 1211 | 506 | 488 | 18 | no | 937 | DOCKER_OK,K3S_OK | **PASS** |
| `all-1248` | 1248 | 1179 | 490 | 488 | 2 | no | 882 | DOCKER_OK,K3S_OK | **PASS** |
| `all-1216` | 1216 | 1147 | 474 | 474 | 0 | **yes** | - | - | **FAIL** (guard fired) |
| `all-1152` | 1152 | 1085 | 443 | 443 | 0 | **yes** | - | - | **FAIL** (guard fired) |
| `all-1088` | 1088 | 1021 | 411 | 411 | 0 | **yes** | - | - | **FAIL** (guard fired) |
| `all-1024` | 1024 | 960 | 381 | 381 | 0 | **yes** | - | - | **FAIL** (guard fired) |
| `full-docker-2048` | 2048 | 1966 | 813 | 631 | 182 | no | 749 | DOCKER_OK | **PASS** |
| `full-k3s-1792` | 1792 | 1714 | 687 | 631 | 56 | no | 1229 | K3S_OK | **PASS** |
| `full-k3s-1728` | 1728 | 1650 | 655 | 631 | 24 | no | 1254 | K3S_OK | **PASS** |
| `full-k3s-1664` | 1664 | 1588 | 624 | 624 | 0 | **yes** | - | - | **FAIL** (guard fired) |
| `full-k3s-1536` | 1536 | 1462 | 561 | 561 | 0 | **yes** | - | - | **FAIL** (guard fired) |
| `full-k3s-1472` | 1472 | 1398 | 529 | 529 | 0 | **yes** | - | - | **FAIL** (guard fired) |
| `full-k3s-1408` | 1408 | 1337 | 499 | 499 | 0 | **yes** | - | - | **FAIL** (guard fired) |
| `neg-a-missing-file` | 2048 | 1966 | 942 | 209 | 732 | no | - | - | **FAIL** (guard fired) |
| `neg-b-no-sentinel` | 2048 | 1966 | 942 | 209 | 732 | no | - | - | **FAIL** (guard fired) |
| `neg-c-no-docker-cli` | 2048 | 1966 | 946 | 183 | 762 | no | - | - | **FAIL** (guard fired) |
| `neg-b-debug` | 2048 | 1966 | 942 | 209 | 732 | no | - | - | **FAIL** (guard fired) |

`k3s-896` was stopped by hand once the kernel had OOM-killed containerd at
102 s of guest time: the payload was then going to sit out its 2400 s pod
timeout, and the verdict was already settled. Its meta file records that. Every
other row ran to its own conclusion.

### The two shapes of failure

They are different problems and the console tells them apart.

**Too small to unpack.** The kernel prints `Initramfs unpacking failed: write
error`, the rootfs line shows 0M free, and the guard stops the boot:

```
[     5.19] rootfs (initramfs): rootfs 202M total, 202M used, 0M free; MemTotal 487M
PAYLOAD_FAIL: initrd truncated (kernel: Initramfs unpacking failed: write error)
```

**Big enough to unpack, too small to run.** No kernel message, the guard passes,
and the test fails honestly. At `-m 960` the `k3s` variant unpacks completely
(cap 377 MiB against 326 MiB of image) and then the kernel OOM-kills its way
through the cluster:

```
[  141.802812] Out of memory: Killed process 1396 (coredns) ...
[  142.082037] Out of memory: Killed process 299 (containerd) ...
K3S_FAIL: pod logs did not carry the marker (got: The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?)
```

(`boot-logs/k3s-960.log`, the two OOM lines trimmed at the right.)

That is the failure mode to want: it names a resource problem and it does not
print `K3S_OK`. The first shape used to be invisible.

### Lifting the cap: `initramfs_options=`

`rootflags=` does **not** apply to the initramfs rootfs; it is ignored, and a
boot with `rootflags=size=90%` truncates exactly as it does without it. The
parameter that does reach that mount is `initramfs_options=`.

```
-append "console=ttyS0 initramfs_options=size=90% test=docker"
```

It works, and it is not a free 100 MiB. On the `docker` variant at **448 MiB**,
which truncates without it, the image unpacks completely every time, and the
test then passes **three runs out of four**. The one failure OOM-killed dockerd
during startup, on the run where the host was busiest (132 s of wall clock
against 37 s for the three passes, and a peak of 242 MiB against 285 to
292 MiB). So `initramfs_options=size=90%` does take the `docker` variant from
560 MiB to 448 MiB, but with no margin: a guest with 70 MiB of rootfs headroom
and 100 MiB of RAM headroom loses a race occasionally. Treat 448 MiB as
reachable rather than as a floor. At **384 MiB** it unpacks and then OOMs every
time.

So the option converts a silent truncation into an honest `DOCKER_FAIL` or
`K3S_FAIL`, which is worth having, and it buys perhaps one size step of real
headroom. It is the thing to reach for when a domU is fixed at a size just under
a variant's floor, not a way to run K3s in 768 MiB.

## The truncation guard

### The failure it exists to stop

With no `root=` and no `rootfstype=` on the command line, the kernel makes the
initramfs rootfs a **tmpfs**, and a tmpfs mounted with no `size=` defaults to
half of RAM. When the image does not fit in that half, the kernel prints one
line and carries on booting:

```
Initramfs unpacking failed: write error
```

Userspace then starts on a partial filesystem. Whether that looks like a bug, a
panic or a pass depends only on where in the archive the cut landed, and the
archive is in sorted order, so it is the same cut every time. On the old
combined image `usr/local/bin/dockerd` was cpio member 1960 and the K3s tree
started at 1961, so a truncation took K3s first and left Docker whole: a
`test=docker` boot printed `DOCKER_OK` and powered off cleanly on an image
missing a third of its files, at every size from 768 to 1024 MiB. Nothing in
that console log says the image was incomplete except the kernel line, 200
lines earlier, which is easy to scroll past.

### What it checks

`/init` runs the check in stage 1, before the copy to tmpfs and before any
test. Two independent checks, because either one alone can be fooled:

1. **The kernel log.** `dmesg` is grepped for `Initramfs unpacking failed`
   before `/init` quietens the log level. This is direct evidence, and it
   depends on the kernel keeping that wording.
2. **A manifest built into the image**, at `/etc/payload-manifest`. This does
   not care what the kernel printed, or why a file is missing. It has three
   parts:
   * a **sentinel**, `/zz-payload-end`, whose name sorts last under `LC_ALL=C`
     so the kernel writes it last. Present and matching its sha256 means the
     unpack reached the end of the stream. The sentinel is two lines of text,
     so hashing it is free.
   * a list of **critical files with their build-time sizes**: `/init`, bash,
     tar, `switch_root`, busybox, find, sha256sum, df, stat, awk, and then the
     engine binaries and image tars of whichever variant this is. 17 to 22
     entries depending on the variant. This is what turns a failure into a
     sentence naming a file.
   * the **total file count and the total size of all regular files**, computed
     at build time by the same walk `/init` repeats at boot: everything under
     `/` except `/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `/newroot` and the
     manifest itself.

On any mismatch it prints, as the first outcome marker on the console:

```
PAYLOAD_FAIL: initrd truncated (<detail>)
```

then the rootfs numbers and the kernel's own initramfs lines, and stops.
`DOCKER_OK` and `K3S_OK` are unreachable after that point, so a log with one of
those markers is a log from a complete image. `PAYLOAD_DONE` is not printed
either: it means the payload ran to the end, and here it did not. With
`debug=1` it drops to a shell on the console instead of powering off, so the
image can be picked over.

`PAYLOAD_START` is still printed before the check. It means the kernel reached
userspace, nothing more.

### What it costs

No checksums over the payload itself. Hashing 200 to 630 MiB under emulation
costs minutes and it would be the slowest thing in a `test=docker` boot. The
count and the byte total catch a short write without reading any file content,
and a partial write cannot change a file's size without moving the byte total
with it.

Measured cost of the whole check, from the payload's own timestamps: **0 to 1
second** on every variant, including `full` at 1551 files. It is one `find`
and one `awk`.

### What it does not check

* It does not detect a file whose **content** changed while its size did not.
  Nothing in the boot path can do that cheaply; use the `.sha256` sidecar on
  the archive before booting if that is the worry.
* It does not check the kernel, only the initrd.
* A manifest that is itself missing gives a different marker,
  `PAYLOAD_FAIL: initrd manifest missing`, because that means the image was not
  built by this `build.sh` rather than that it was cut short.
* `usr/bin/awk` is a symlink, and `stat` reports a symlink's own size, so its
  manifest entry is the length of the link target string rather than the size
  of `mawk`. That is consistent between build and boot, and `mawk` itself is
  covered by the file count and the byte total.

### Proof that the guard fires

Four boots on images damaged on purpose, all at `-m 2048` so the kernel has
room to unpack everything it is given and prints **no** message about the
initramfs. The manifest check is what catches all four, which is the point of
having it: it does not depend on the kernel saying anything.

| Image | What was done to it | What the payload printed |
|---|---|---|
| `neg-a-missing-file` | one 1740-byte file removed (`usr/share/terminfo/l/linux`), archive otherwise valid and complete | `PAYLOAD_FAIL: initrd truncated (1152 files / 218317580 bytes, the manifest says 1153 / 218319320)` |
| `neg-b-no-sentinel` | `/zz-payload-end` removed | `PAYLOAD_FAIL: initrd truncated (last archive member /zz-payload-end is missing)` |
| `neg-c-no-docker-cli` | `usr/local/bin/docker` removed | `PAYLOAD_FAIL: initrd truncated (/usr/local/bin/docker is missing)` |
| `neg-b-no-sentinel` with `debug=1` | same as above | the same `PAYLOAD_FAIL`, then `debug=1: dropping to a shell instead of powering off` and a root prompt on the console |

`DOCKER_OK` appears in none of them. The first one is the interesting row: a
single small file, deleted from a properly rebuilt archive, in an image where
everything the Docker test touches is present and would have passed.

And on a real truncation, from the RAM scan above:

```
PAYLOAD_START
[     5.19] rootfs (initramfs): rootfs 202M total, 202M used, 0M free; MemTotal 487M
PAYLOAD_FAIL: initrd truncated (kernel: Initramfs unpacking failed: write error)
[     5.28] payload: the image is incomplete, so no test was run and no test
[     5.30] payload: marker will be printed. Give the guest more RAM, or boot a
[     5.31] payload: smaller variant, or add initramfs_options=size=90% (see NOTES).
[     5.40] rootfs (at the failure): rootfs 202M total, 202M used, 0M free; MemTotal 487M
```

(`boot-logs/docker-544.log`.)

The old combined image, in a guest too small for it, printed `DOCKER_OK` here
instead, and powered off reporting success.

### And that the normal path still passes

| Variant | Command line | Result |
|---|---|---|
| `docker` | `test=docker`, `-m 640` | `DOCKER_OK`, `SUMMARY: docker=ok k3s=skipped`, `PAYLOAD_DONE`, power down, QEMU exit 0 |
| `k3s` | `test=k3s`, `-m 1024` | `K3S_OK`, node `domu Ready control-plane v1.37.0+k3s1 10.0.2.15 ... containerd://2.3.4-k3s1`, `PAYLOAD_DONE` |
| `all` | `test=all`, `-m 1280` | `DOCKER_OK` then `K3S_OK`, `SUMMARY: docker=ok k3s=ok`, `PAYLOAD_DONE` |
| `full` | `test=docker`, `-m 2048` | `DOCKER_OK`, `PAYLOAD_DONE` |
| `full` | `test=k3s`, `-m 1728` | `K3S_OK`, `PAYLOAD_DONE` |
| `docker` | `test=all`, `-m 1024` | `payload: this image has no K3s stack, running test=docker`, then `DOCKER_OK` and `SUMMARY: docker=ok k3s=skipped: not in this image variant` |

Every row above is from an older build. On the shipped files, the `all`
variant was booted twice at 1344 MiB: once bare, the way every earlier boot in
this document ran, and once with a block device and a network interface
attached, so the two new code paths get exercised rather than only skipped.

| | bare | with a disk and a NIC |
|---|---|---|
| log | `boot-logs/nd-all-1344-bare.log` | `boot-logs/nd-all-1344-nic-disk.log` |
| QEMU devices | `-nic none`, no drive | virtio-blk 128 MiB, virtio-net `restrict=y` |
| append | `test=all` | `test=all disk.dev=/dev/vda` |
| network | `no real interface; falling back to dummy0` | `real interface eth0 present (driver virtio_net)` |
| node address | 10.0.2.15 on `dummy0` | 10.0.2.15 on `eth0` |
| `DISK_OK` | 0, `disk=skipped: no block device at /dev/xvda` | **1** |
| `DOCKER_OK` / `K3S_OK` | 1 / 1 | 1 / 1 |
| summary | `SUMMARY: docker=ok k3s=ok disk=skipped: …` | `SUMMARY: docker=ok k3s=ok disk=ok` |
| rootfs | 537M total, 488M used, 49M free, MemTotal 1272M | the same |
| guard | 1548 files, 510090752 bytes, 28 named, 3 s | the same |
| peak used | 877M of 1272 | 879M of 1272 |
| wall, exit | 431 s, 0 | 437 s, 0 |

Both ran `-M virt -m 1344 -smp 4 -nographic -no-reboot` on `Image` sha256
`542e9cec…91e3359b`, neither logged `Initramfs unpacking failed`, an OOM kill
or a panic, and every marker is on a line of its own. In the second boot K3s
registered the node at 10.0.2.15 over the real interface:

```
k3s: domu Ready control-plane 27s v1.37.0+k3s1 10.0.2.15 ... containerd://2.3.4-k3s1
```

`Hello from Docker!` appears twice in each log, once from `docker run` and once
from `kubectl logs`. The hello-world message names the architecture it ran on,
so every copy carries `(riscv64)`.

Two shorter boots on the `docker` variant with `test=disk` isolate the new code
from the slow tests: `boot-logs/smoke-disk-vda.log` (disk only, 45 s) and
`boot-logs/smoke-nic-disk.log` (disk and NIC, 34 s, which is where the
`driver virtio_net` line was first seen).

### Proof that the new markers are gated

A marker that has only been seen to pass is not known to be gated. Each gate
was therefore run against a payload that does the work and then produces the
wrong answer. Where that needed a code change it was one line, the variant was
rebuilt into a scratch directory so the shipped archives were never touched,
and `init` was restored afterwards and checked back to sha256
`d5d80f73…9082c866`.

| Gate | What was changed | Boot | What the payload printed | marker count |
|---|---|---|---|---|
| `DOCKER_OK` | the Docker run becomes `busybox echo NEGATIVE_CONTROL` | `docker`, `test=docker`, `-m 640`, 87 s | `DOCKER_FAIL: the container did not print 'Hello from Docker!' (got: NEGATIVE_CONTROL)` | 0 |
| `K3S_OK` | the pod becomes `busybox` with `command: ["sh", "-c", "echo NEGATIVE_CONTROL"]` | `k3s`, `test=k3s`, `-m 1152`, 373 s | `K3S_FAIL: pod logs did not carry 'Hello from Docker!' (got: NEGATIVE_CONTROL)` | 0 |
| `DISK_OK`, readback | the file written to the filesystem becomes `NEGATIVE_CONTROL` instead of the nonce | `docker`, `test=disk`, `-m 640`, 36 s | `DISK_FAIL: the remounted filesystem gave back something else (wrote 'DISK_PAYLOAD a6f58d4a…', read 'NEGATIVE_CONTROL')` | 0 |
| `DISK_OK`, device unwritable | nothing; the disk is attached `readonly=on` | `docker`, `test=disk`, `-m 640`, 30 s | `DISK_FAIL: raw write of 1048576 bytes to /dev/vda failed` | 0 |
| `DISK_OK`, device absent | nothing; no drive attached at all | `all`, `test=all`, `-m 1344`, 431 s | `disk=skipped: no block device at /dev/xvda`, and no marker of any kind | 0 |

Logs: `neg2-hello-docker-640`, `neg-hello-k3s-1152` (run against the previous
`init`, whose Docker and K3s gate code is byte-identical to this one's),
`neg-disk-readback`, `neg-disk-readonly` and `nd-all-1344-bare`, all under
`boot-logs/`. The one-line changes are saved as
`../validation/negative-control/init-hello-docker.diff`, `init-hello-k3s.diff`
and `init-disk-readback.diff`, beside the equivalent diff from the original
marker.

In every case the work really happened and only the answer was wrong. The
Docker log shows both tars loading and then `NEGATIVE_CONTROL` where the
hello-world text belongs. The K3s log shows a pod that reached Succeeded. The
disk readback control passed the raw half, made an ext4 filesystem, mounted it,
unmounted and remounted it, and only then found the wrong contents. The
read-only control shows the device correctly detected and sized before the
write failed. And every one of these boots still reaches `PAYLOAD_DONE`,
because a failed test is an honest result rather than a broken payload.

Note that the Docker negative-control log does contain the string `Hello from
Docker!` twice, both times inside the failure message quoting what was
expected. That is the reason the grepping advice below says to anchor to the
whole line.

Seccomp inside the container, from every passing Docker boot:

```
Seccomp:	2
Seccomp_filters:	1
```

`Seccomp: 2` is filter mode, which is what the payload is checking for.

### The console logs

Every boot in the table above is in `boot-logs/`, with a `.meta` file beside it
recording the QEMU command line, the sha256 of the kernel and the initrd used,
and the wall time. `boot-logs/run-boot.sh` is the wrapper that produced them,
`boot-logs/make-damaged-images.sh` rebuilds the three damaged images, and
`boot-logs/verdict.py` is the reader; it treats `Initramfs unpacking failed` as
a failure regardless of which markers printed, which is how the numbers in this
file differ from the ones in the first version.

## What was dropped to shrink it

The old combined image was 533 393 901 B unpacked. The new `all` image, which
carries the same two stacks and the same four airgap images, is 510 067 126 B:
23 326 775 B less. That splits into

| Dropped | Bytes | Why it was safe |
|---|---|---|
| `docker-proxy` | 2 219 896 | Only used to publish ports. The tests run `--network none` and publish nothing, and `dockerd` is now started with `--userland-proxy=false` so it never looks for the binary. |
| `docker-init` (tini) | 512 992 | Only used by `docker run --init`, which the payload never passes. |
| Debian base trim | 20 593 887 | perl, apt, dpkg and their libraries, the dpkg database, `sqv`, `libstdc++`, `/usr/share/{common-licenses,bash-completion,keyrings,gcc,base-files,ca-certificates,perl5}`, all of `/usr/share/zoneinfo` except `UTC`, and the systemd leftovers. Nothing in the payload runs a package manager. |

Two other candidates were measured and rejected, which is worth recording so
nobody spends the afternoon again:

* **Stripping the K3s tree saves nothing.** The unpacked `k3s` multicall binary
  is 216 862 032 B and `riscv64-linux-gnu-strip` returns it byte for byte the
  same size; `runc` in that tree is identical too, and the shim and `cni` give
  back 20 KB between them. The release is already stripped. That 207 MiB is
  simply what K3s is, and it is why the `k3s` variant cannot get much under
  325 MiB.
* **Pruning unreferenced shared libraries is not worth the risk.** Walking the
  `DT_NEEDED` closure of every binary in the tree, with apt, dpkg and perl
  excluded, leaves 5.9 MB of unreferenced `.so` files, and most of that is
  `libstdc++` (taken anyway, above) plus things no sane person deletes
  (`ld-linux-riscv64-lp64d.so.1`, the `libnss_*` modules, `librt`,
  `libpthread`). What is left over is under 1 MB.

What was **not** dropped, and why:

* The **Docker CLI** (27 063 256 B) stays. `/init` drives the test through
  `docker version`, `docker info`, `docker load` and `docker run`, and
  replacing that with `ctr` would stop the test being a Docker test.
* **containerd** (44 118 696 B) stays; Docker 29 needs it.
* The **hello-world and busybox image tars** are shared. `/init` `docker
  load`s both from `/var/lib/rancher/k3s/agent/images/`, the same files K3s
  imports for its airgap test, so each is stored once even in the `all`
  variant. In the `docker` variant that directory holds only those two, which
  is an odd-looking path for an image with no K3s in it, but it keeps one code
  path.
* **coredns and local-path-provisioner** stay in the `k3s` variant. Disabling
  them as well would take 36 MiB of image tars out and lower the floor further,
  but a K3s cluster that runs no DNS is a weaker claim than the one this
  payload is here to make. That trade is available on the command line
  (`--disable` is built from `k3s.full`), it is just not the default.

At runtime `/init` also frees what it no longer needs, which does not lower the
floor (the unpack has already happened) but does lower the peak:

* with `test=docker`, the busybox tar is deleted after `docker load`;
* with `test=k3s` or `test=all`, the airgap tars are deleted once the node is
  `Ready`, since containerd has imported them by then. That is 37 MiB of tmpfs
  on the `k3s` variant and 180 MiB on `full`;
* `test=all` still deletes the whole Docker stack before K3s starts, as before;
* `test=disk` frees both stacks before it starts, which is why a disk-only boot
  finishes with about 76 MiB used on a 583 MiB guest.

`keep=1` disables all of it.

## What is inside

### Base

Debian trixie riscv64 (`debian:trixie-slim`), plus `bash busybox ca-certificates
iproute2 iptables mawk mount procps util-linux`. Docs, man pages, locales, apt
lists, the gconv modules and everything in the trim table above are deleted. No
systemd, no kmod: the kernel has everything built in, and `/init` is a bash
script. What is left is 48 720 080 B.

Because the trim deletes shared libraries, `build.sh` no longer only looks for
the commands `/init` needs: it **runs** each of them inside a riscv64 container
and fails the build if one will not start. A binary whose loader cannot resolve
a `NEEDED` entry is still on `PATH` and still passes `command -v`.

### Docker, from our own release

Engine assets from `gounthar/docker-for-riscv64` release **`v29.8.0-riscv64`**
(published 2026-09-04), CLI from **`cli-v29.8.0-riscv64`**. Debian's Docker is
deliberately not used: our `runc` is built with seccomp, which the payload
checks for.

sha256 of the files as downloaded from the release:

```
ab7cc56ee3799737bb43d4048b38a2bd41acd539620542920ff23af40d0884f3  dockerd
fbb87aa7a4df947ae145413e0d4ef6ac35bb612652bc11ca38522a968a3e01b1  containerd
bb5f428d32521aadb1b288dd104f16ffc71d962f712534873ef880380d551731  containerd-shim-runc-v2
19a367d250a539b5543193b60969c29ca4c014063eb9ace9025fabe2127d54e8  runc
994e8d6a9aa980004fa6cca200a501500072967f96367e05f7bf49af34fc51b7  docker
09d54deb6941ebaa4daf7c573d095b2b711631836c2fc44ac9ddf0d00b4657e4  k3s-riscv64
```

`build.sh` verifies these before using anything, and also checks `k3s-riscv64`
against the `.sha256sum` asset shipped with the release. `docker-proxy` and the
tini rpm are no longer downloaded at all.

The Go binaries are stripped (`STRIP=0` turns that off) because the released
`dockerd`, `runc`, `docker` and `docker-proxy` still carry debug info; that
saves 47 MiB uncompressed. sha256 of what is actually in the image:

```
577986f53717611d7a94a89b98daa04193009c20c25a769c20389085cae9655b  dockerd     (79 236 792 B, was 92 614 720)
fbb87aa7a4df947ae145413e0d4ef6ac35bb612652bc11ca38522a968a3e01b1  containerd  (44 118 696 B, already stripped)
ad86b7c21099e73a024fae2070c83faab1c8930f711d0a203aa96b1399ce678c  containerd-shim-runc-v2 (8 065 144 B)
faf15e2149f96b310a87e1d8a32b9beec91c96c197698b844d94db93a253ea8e  runc        (11 115 352 B, was 16 098 264)
bf053b42d0a02d9fc96773c4110d614ee3aa941f81bacdb9579bbe3daeaf55bf  docker      (27 063 256 B, was 40 008 248)
```

Versions as the binaries report them, run under riscv64 emulation during the
build:

```
Docker version 29.8.0, build HEAD              (dockerd)
Docker version v29.8.0, build                  (docker CLI)
containerd github.com/containerd/containerd/v2 v2.2.1 dea7da592f5d1d2b7755e3a161be07f43fad8f75
runc version 1.4.0 / spec 1.3.0 / go1.24.4 / libseccomp: 2.6.0
```

`runc --version` does print a `libseccomp:` line, so the seccomp requirement is
met at build time; the payload proves it at runtime as well (see markers).

**Swapping in `v29.8.1-riscv64`**: change `ENGINE_TAG` (and `CLI_TAG`, if a
matching CLI release exists) at the top of `build.sh`, run once with
`SKIP_VERIFY=1`, and paste the printed checksums into the `PINNED_SHA256` block.
Nothing else depends on the version.

### K3s

Our release **`k3s-v1.37.0-k3s1-riscv64`** (published 2026-09-19), asset
`k3s-riscv64`, verified against `k3s-riscv64.sha256sum`. `k3s version
v1.37.0+k3s1 (bb7cf065)`, go1.26.7.

The initrd does **not** contain the released binary. The K3s binary is a
self-extracting bundle: on first `k3s server` it unpacks 244 MiB into
`/var/lib/rancher/k3s/data/<hash>/` and re-execs out of there. Doing that at
boot would cost both the 77 MiB stub *and* the 244 MiB unpacked tree in RAM, and
the unpack itself took 3m50s under emulation. So `build.sh` unpacks it at build
time, at the exact path it will run from (the CNI symlinks it writes are
absolute, so it cannot be unpacked elsewhere and moved), verifies the unpacked
tree against the bundle's own `.sha256sums`, and ships only that. `/init` then
runs `/var/lib/rancher/k3s/data/current/bin/k3s server`, which is how the
upstream `rancher/k3s` container image runs K3s too.

`data/current` is an **absolute** symlink into the hashed directory. It resolves
at boot, and it does not resolve in the build's staging directory, which is why
`build.sh` reads the link and stats through the hashed name when it writes the
manifest.

FORTH's binary (`CARV-ICS-FORTH/k3s`, release `20260817`, asset `k3s-riscv64`)
is **not** included. It stays the documented fallback: it is a different build of
a different version, and including it would add another ~80 MiB for a path we do
not intend to take. To use it, drop it in place of ours in `build.sh`'s
download list.

### Airgap images

From the release asset `k3s-images-riscv64.txt`, plus `hello-world`, which is
not a K3s image at all: it is what both tests run, and it rides in the same
directory so K3s imports it for the pod. All nine refs have a `linux/riscv64`
variant on Docker Hub, checked with `skopeo inspect --raw`:

| Image | in `docker` | in `k3s` and `all` | in `full` | size of the tar |
|---|---|---|---|---|
| `docker.io/hello-world:latest` | yes | yes | yes | 22 016 B |
| `docker.io/busybox:1.37.0` | yes | yes | yes | 1 956 864 B |
| `docker.io/carvicsforth/pause:3.10.2` | no | yes | yes | 290 816 B |
| `docker.io/rancher/mirrored-coredns-coredns:1.14.7` | no | yes | yes | 22 583 808 B |
| `docker.io/rancher/local-path-provisioner:v0.0.37` | no | yes | yes | 14 117 376 B |
| `docker.io/rancher/klipper-helm:v0.13.3-build20260727` | no | no | yes | 69 464 576 B |
| `docker.io/carvicsforth/klipper-lb:v0.4.17` | no | no | yes | 5 065 728 B |
| `docker.io/rancher/mirrored-library-traefik:3.7.13` | no | no | yes | 53 640 192 B |
| `docker.io/carvicsforth/metrics-server:v0.9.0` | no | no | yes | 22 061 568 B |

The `k3s`/`all` set is what `--disable traefik,servicelb,metrics-server` actually
needs: pause (sandbox), coredns, local-path-provisioner (deployed by default),
plus hello-world (the test pod) and busybox (the seccomp check).
`hello-world:latest` is the one ref pinned by a moving tag rather than a
version, because that is the only tag the image publishes.

klipper-lb is only used by servicelb, so it is not reachable in the default
configuration.

klipper-helm is **not** quite in that position, and the line above used to say
it was. The K3s server log tail printed by the K3s negative control
(`boot-logs/neg-hello-k3s-1152.log`) shows a `helm-install-gateway-api-crd` job
sitting in `ImagePullBackOff` on `rancher/klipper-helm:v0.13.3-build20260727`,
with traefik, servicelb and metrics-server all disabled. It does not stop the
node reaching Ready or the test pod running, and it costs nothing but a
back-off loop. Whether it is also present on the passing boots is not known
from the logs here: that server-log tail is only printed on a `K3S_FAIL`.

The tars are produced with `docker pull --platform linux/riscv64` +
`docker save --platform linux/riscv64`, which on a daemon using the containerd
image store writes an archive carrying both `manifest.json` (RepoTags, so
`docker load` is happy) and an OCI `index.json` with
`io.containerd.image.name` annotations (so containerd imports them under their
full names), with the layer blobs left gzip-compressed. They live in
`/var/lib/rancher/k3s/agent/images/`, which K3s imports at agent start.

sha256 of the four:

```
e3c7042fceb5aa3a842cb4297adfaa505f0b8cde633011c5445d80c1f85e39dd  pause-3.10.2.tar
259360cc7876cf2e5b5666f06fc00d96d7fa047f28336a187e6d0dfd94684882  mirrored-coredns-coredns-1.14.7.tar
58bf52efaa7a435c050a5569d844487d165770357766b43d5e6c8bb80e8f3be3  local-path-provisioner-v0.0.37.tar
056eda23eecd9a32dc85c3bf284009dab703f524c4ebae2cd3865c6f5afa05ba  busybox-1.37.0.tar
```

## Two kernels, and which is which

This directory ships a kernel, and it is **not** the kernel the domU will run.
Both an agent doing the RAM sizing and an agent doing this work read
`kernel/config-7.2.6`, found no `CONFIG_XEN` in it, and drew a conclusion about
the domU. The layout invites that substitution, so it is written down here.

| | `kernel/Image`, `kernel/config-7.2.6` | the domU kernel |
|---|---|---|
| Where | next to this payload | `~/xen-riscv/out/container/` on the build machine (`Image`, `Image.gz`, `.config`, `System.map`) |
| Built from | riscv `defconfig` + `kernel/container.config` | `baptleduc/linux-xen-riscv`, branch `6.18-xen-guest-support`, which carries the `arch/riscv/xen` commits |
| Xen support | **none.** The only two lines matching `xen` are `CONFIG_NETXEN_NIC` and `CONFIG_MMC_SDHCI_XENON`, unrelated NIC and MMC drivers | `CONFIG_XEN=y`, `CONFIG_XEN_NETDEV_FRONTEND=y`, `CONFIG_XEN_BLKDEV_FRONTEND=y`, `CONFIG_XEN_XENBUS_FRONTEND=y`, `CONFIG_XEN_GNTDEV=y`, `CONFIG_XEN_GRANT_DMA_ALLOC=y`, and 145 `xennet_`/`blkfront_`/`xenbus_` symbols in `System.map` |
| What it is for | plain-QEMU validation: every boot in this document | the Xen guest, where netfront and blkfront actually appear |

So "the payload kernel has no Xen support" is true and says nothing about the
domU. A guest booted on `kernel/Image` will only ever see the virtio path,
which is exactly what was validated here.

Everything the two new code paths depend on is also `=y` in the domU kernel,
checked in its `.config` rather than assumed: `EXT4_FS` with
`EXT4_USE_FOR_EXT2` (so `busybox mke2fs` plus `mount -t ext4` works there too),
`VFAT_FS` for the fallback, `DUMMY` so the no-NIC fallback still exists,
`OVERLAY_FS`, `CGROUPS` and `SECCOMP`.

### What the interface line will say on the domU

`vif`, not `xen-netfront`. The payload prints the basename of
`/sys/class/net/<dev>/device/driver`, and `xenbus_register_driver_common` sets
`drv->driver.name = drv->name ? drv->name : drv->ids[0].devicetype`
(`drivers/xen/xenbus/xenbus_probe.c:376`). Neither frontend sets `.name`, and
their id tables are `{ "vif" }` and `{ "vbd" }`, so:

```
net: real interface eth0 present (driver vif), using it
```

The `device` symlink the payload keys on is there: `xen-netfront.c:1757` calls
`SET_NETDEV_DEV(netdev, &dev->dev)`, so a netfront `eth0` has a parent device
in sysfs and the primary rule fires. If that ever stopped being true the name
check behind it would still pick `eth0`, which is why the rule has two tiers.

None of this has been booted. It is read out of the sources and the config.

## The kernel command line

Everything is parsed from `/proc/cmdline` by `/init`; unknown words are ignored,
so it is safe to keep `console=`, `earlycon=` and friends.

| Option | Default | Meaning |
|---|---|---|
| `test=all\|docker\|k3s\|disk` | `all` | which tests to run; `all` runs disk, then Docker, then K3s |
| `debug=1` | off | drop to a shell on the console instead of powering off, including after `PAYLOAD_FAIL` |
| `keep=1` | off | do not delete the unused stack or the imported image tars (implied by `debug=1`) |
| `k3s.full=1` | off | do not disable traefik, servicelb and metrics-server |
| `k3s.cfgtimeout=SEC` | `120` | budget for the server to write its kubeconfig; raise it under Xen, where 120 s ran out before the API server answered |
| `k3s.restarts=N` | `0` | restart the K3s server up to N times if it exits (same data dir, remaining budget); the result then says `ok (after N server restart(s))` |
| `k3s.timeout=SEC` | `1800` | budget for the node to reach Ready |
| `k3s.podtimeout=SEC` | `900` | budget for the test pod to finish |
| `docker.timeout=SEC` | `600` | budget for each `docker run` in the test |
| `docker.storage=NAME` | probe | force a storage driver instead of probing overlayfs |
| `disk.dev=PATH` | `/dev/xvda` | block device for the disk test; absent means the test is skipped |
| `disk.timeout=SEC` | `300` | budget for each individual disk operation |
| `root.size=SIZE` | `90%` | size of the tmpfs the real root lives in |
| `net.addr=CIDR` | `10.0.2.15/24` | address put on whichever interface was chosen |
| `net.gw=IP` | `10.0.2.2` | gateway for the default route |
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
| `progress=SEC` | `30` | interval between progress lines while waiting |

`test=all` on a single-stack image is reduced to the test that image can run,
and says so: the payload reads `variant=` out of its own manifest. Asking for
`test=k3s` on the `docker` image prints a warning naming the variant, so the
`K3S_FAIL: no k3s binary` that follows cannot be mistaken for a truncated image.

Two kernel options matter here and are not `/init`'s:

* **`initramfs_options=size=90%`** lifts the half-of-RAM cap on the initramfs
  rootfs, and is the workaround for a domU too small for a variant. It is worth
  knowing and it is not free: see the RAM section for what it buys and what it
  turns a truncation into.
* **`rootflags=`** does **not** reach that mount and is silently ignored. It was
  tried and measured.

The timeouts are there because everything is slow under TCG. Raise them rather
than concluding a hang: progress lines carry a timestamp, the elapsed/budget
counter, the last K3s log line and the memory left, so a silent hang and slow
progress look different.

Typical lines:

```
-append "console=ttyS0 test=all k3s.timeout=3600 k3s.podtimeout=1800 progress=60"
-append "console=ttyS0 test=docker debug=1"
```

## Markers

Each on its own line, in this order:

```
PAYLOAD_START
PAYLOAD_FAIL: initrd truncated (<detail>)    (and then nothing else)
DISK_OK              or  DISK_FAIL: <reason>     (neither, if there is no device)
DOCKER_OK            or  DOCKER_FAIL: <reason>
K3S_OK               or  K3S_FAIL: <reason>
PAYLOAD_DONE
```

`SUMMARY: docker=... k3s=... disk=...` is printed just before `PAYLOAD_DONE`.
**The `disk=` field is new**, so anything matching the old two-field line
exactly needs updating. A test that was not selected reports `skipped` there and
prints neither marker; on a single-stack image the other test reports
`skipped: not in this image variant`; and the disk test reports
`skipped: no block device at <path>` when the guest has no such device, which is
not a failure.

`PAYLOAD_START` means the kernel reached userspace and nothing more. It is
printed on an image missing a third of its files, and before the first version
of this payload that was easy to misread.

The markers are printed by `/init` itself, never by a container, and only after
the result has been checked: the container's own output is captured, printed as
evidence under a `docker:`/`k3s:` label, and matched against `Hello from
Docker!`. No container prints a marker string, so `grep -c '^DOCKER_OK$'` on
the console log is 1 on success and 0 otherwise. On failure the reason is on
the same line and the last 30 to 40 lines of the relevant daemon log follow.

After `PAYLOAD_DONE` the machine powers off (`busybox poweroff -f`, falling back
to sysrq `o`), so QEMU exits on its own. With `debug=1` it drops to a bash shell
on the console instead. `PAYLOAD_FAIL` also powers off, and does not print
`PAYLOAD_DONE`.

When grepping, anchor to the whole line: a failure message quotes what the
container printed, so a bare substring search can match `DOCKER_OK` inside a
`DOCKER_FAIL` line.

## What `/init` does

### Stage 1: check the image, then get off the initramfs

`runc` cannot `pivot_root` out of the initramfs rootfs, so Docker would need
`DOCKER_RAMDISK=true` and K3s/containerd would fail outright. Stage 1 therefore:

1. mounts `/proc`, `/sys`, `/dev` (devtmpfs), prints `PAYLOAD_START`, parses the
   command line;
2. prints the rootfs line: the type of `/`, its total size, how much of it the
   image used and how much is left, and `MemTotal`. **That is the number that
   explains a truncated boot**, and it is printed on every boot, passing or not;
3. runs the truncation guard described above, and stops there if it fails;
4. quiets the console log level to 4 unless the command line set
   `loglevel=`/`quiet` itself;
5. mounts a tmpfs on `/newroot` (`size=90%` by default, a limit rather than a
   reservation);
6. **copies** `/bin /sbin /lib* /usr/bin /usr/sbin /usr/lib /usr/libexec` and
   `/init` across. These are the files the running bash and tar are executing
   from; deleting a mapped loader in the middle of the pipeline is a race, and
   `switch_root` deletes the initramfs copies anyway;
7. **moves** everything else with `tar --remove-files | tar -x`, so the
   initramfs copy is freed as the tmpfs copy is written and the peak stays near
   one copy rather than two;
8. `exec switch_root /newroot /init`, with `PAYLOAD_STAGE2=1` in the environment
   so the same script knows which half to run.

### Stage 2: the real root

- `/dev/pts`, `/dev/shm`, `/run`, `/tmp`, the `/dev/fd`, `/dev/stdin` symlinks,
  and `mount --make-rshared /` (containerd needs propagation from the root).
- the rootfs line again, this time for the tmpfs root.
- the variant is read back out of the manifest and the requested test reconciled
  against it, into three independent run flags rather than by rewriting
  `test=`. The disk test belongs to no variant, since it depends on the guest
  having a block device rather than on what is in the image, so reducing
  `test=all` to `test=docker` on a docker-only image would have silently
  dropped it. The payload prints what it settled on:
  `payload: will run disk=1 docker=1 k3s=0`.
- **cgroup v2 only**, mounted at `/sys/fs/cgroup` with
  `nsdelegate,memory_recursiveprot`. Every pid in the root cgroup is moved into
  `/sys/fs/cgroup/init` first, then every controller listed in
  `cgroup.controllers` is written to `cgroup.subtree_control`. Moving init out
  first is what makes the delegation stick, and it keeps the root cgroup free of
  processes for kubelet and dockerd. Observed on the test kernel: `cpuset cpu io
  memory hugetlb pids`, all delegated.
- **Network, with a real interface if there is one.** `lo` goes up, then the
  payload looks for a real NIC: something under `/sys/class/net` that is not
  `lo`, not a `dummy*`, not one of the tunnel stubs, and that has a parent
  device in sysfs. A netfront or virtio-net `eth0` qualifies; `dummy0` does
  not, because a purely virtual interface has no parent device. Whatever wins
  gets `net.addr` and the default route via `net.gw`, and the payload says
  which it picked and with which driver:

  ```
  net: real interface eth0 present (driver virtio_net), using it
  net: using eth0 (real) with 10.0.2.15, node will register as that
  ```

  **That line is the evidence the frontend came up at all**, which is why it
  names the driver. On the domU it will read `driver vif`, not
  `xen-netfront`; see "Two kernels, and which is which". With no NIC the
  payload falls back to `dummy0` and says so, and everything downstream is
  unchanged:

  ```
  net: no real interface; falling back to dummy0
  net: using dummy0 (dummy) with 10.0.2.15, node will register as that
  ```

  `dummy0` was only ever a stand-in. K3s refuses to start without a default
  route and picks its node IP from the route's interface, so something has to
  carry an address. If there is no NIC *and* `CONFIG_DUMMY` is missing, this
  prints a warning and K3s will fail, and that is the failure to look for
  first.
- **No DHCP.** Addressing is static, from `net.addr` and `net.gw`. The first
  domU milestone is an isolated bridge with no uplink and no DHCP server, so
  there would be nothing to answer a request.
- The address is **read back off the interface** rather than assumed, and
  `/etc/hosts` is rewritten from what is actually there. K3s registers the node
  by that address, so the two must not drift. `setup_system` writes the file
  early with the address from the command line, and `setup_network` writes it
  again once the address has stuck.
- `/etc/hosts`, `/etc/resolv.conf` (`nameserver 10.0.2.3`, unreachable on
  purpose), `/etc/machine-id`, hostname `domu`, `ip_forward=1`,
  `bridge-nf-call-iptables=1`, higher inotify limits.
- A domU with no RTC boots in 1970; if the clock is older than the build date,
  it is set to the build date, so K3s's self-signed certificates are not issued
  in the past.

### Docker test

1. `containerd` is started, then `dockerd` pointed at it, with
   `--userland-proxy=false` because `docker-proxy` is not shipped.
2. The storage driver is **probed**, not assumed: `/init` mounts a throwaway
   overlay on the tmpfs root. If that works (it does on the part A kernel),
   dockerd runs with its defaults, which is Docker 29's containerd image store
   with the `overlayfs` snapshotter. If it does not, the fallbacks are
   `--storage-driver native` then `vfs`, and if dockerd still refuses to start,
   the whole sequence is retried with
   `--bridge none --iptables=false --ip6tables=false`. Whatever combination
   worked is printed as `docker: dockerd started with: ...`.
3. `docker load` of the hello-world and busybox tars, then
   `docker run --rm --network none hello-world:latest` with no command. The
   output is printed and then matched against `Hello from Docker!`; only a
   match reaches `DOCKER_OK`. On a `test=docker` boot both tars are deleted
   once they are loaded.
4. `docker run --rm --network none busybox:1.37.0 grep Seccomp /proc/self/status`
   with the default seccomp profile, printed in full. `Seccomp: 2` (filter mode)
   is required: anything else is a `DOCKER_FAIL`, because a runc built with
   seccomp that does not actually install a filter is exactly the regression
   this payload exists to catch. This check runs busybox rather than
   hello-world because it has to read `/proc/self/status` from inside a live
   container.
5. `runc --version` is printed, including its `libseccomp:` line.

### Disk test

Runs first in `test=all`: it is the cheapest of the three by a wide margin, it
shares nothing with the other two, and a disk failure reported up front beats
one reported behind several minutes of K3s.

If `$DISK_DEV` (default `/dev/xvda`) is not a block device, the test prints the
devices the kernel does know about, records `skipped`, and prints **no marker**.
That is the path every plain-QEMU boot takes, and it is not a failure.

If the device is there, **its contents are destroyed**. The test writes from
byte 0 and then makes a filesystem over the top; the payload says so on the
console before it starts. Give it a scratch device.

Two halves, both of which must pass before `DISK_OK`:

1. **Raw.** 1 MiB of fresh `/dev/urandom` bytes to a file, sha256 it, `dd` it to
   the device with `conv=fsync`, `sync`, drop the page cache through
   `/proc/sys/vm/drop_caches`, read the same length back, sha256 that, compare.
   The bytes are generated per boot, so nothing already on the device can
   satisfy it.
2. **Filesystem.** mkfs, mount, write a file containing a 16-byte random nonce,
   `sync`, unmount, drop caches, remount, read the file back, compare. The
   unmount and remount are the point: this is the half that proves the driver
   carries real filesystem traffic rather than one `dd`. The nonce is there so
   a file left by an earlier boot cannot satisfy the check.

The filesystem comes from **busybox**, not e2fsprogs, which is not in the image:
`busybox mke2fs` writes an ext2 image and the kernel has `CONFIG_EXT4_FS` with
`CONFIG_EXT4_USE_FOR_EXT2`, so it mounts through the ext4 driver. If that fails
the payload falls back to `busybox mkdosfs` and vfat, which is also built in.
Measured: ext4 wins on the first try, and the vfat path has never been taken.
Neither adds a byte to the image, since busybox is already shipped for the
seccomp check.

On any failure `DISK_FAIL: <reason>` names what happened and the payload prints
`/proc/partitions` and the kernel's own lines about block devices.

### K3s test

`k3s server --data-dir /var/lib/rancher/k3s --disable
traefik,servicelb,metrics-server --write-kubeconfig-mode 644 --node-name domu`,
with the bundled `bin` first on `PATH` and `bin/aux` (iptables, nft, conntrack)
last, the way the K3s stub sets it up. Flannel stays on its default VXLAN
backend; the server log goes to `/var/log/k3s.log` and its last line is echoed
in every progress line.

kubelet's eviction thresholds are lowered
(`memory.available<32Mi,nodefs.available<2%,imagefs.available<2%`) because the
root is a tmpfs sized at 90% of RAM: with the stock thresholds a fairly normal
90%-full tmpfs would put the node under DiskPressure and nothing would ever be
scheduled.

Then: wait for the kubeconfig, wait for the node to be Ready, delete the airgap
tars now that containerd has imported them, apply a pod

```yaml
image: hello-world:latest
imagePullPolicy: Never
```

with no `command`, so the image's own entrypoint runs; wait for it to reach
Succeeded, print `kubectl logs` and match them against `Hello from Docker!`.
`imagePullPolicy: Never` is what makes it an airgap test: if the airgap import
did not work, the pod fails instead of quietly pulling.

With `k3s.full=1` nothing is disabled; on anything but the `full` variant that
also prints a warning naming the images that are missing, because traefik and
metrics-server will then sit in ImagePullBackOff (which does not stop the node
from going Ready or the test pod from running).

## Build

```bash
./build.sh                          # docker, k3s and all
VARIANT=docker ./build.sh           # one variant
VARIANT=docker,k3s,all,full ./build.sh
```

Needs `docker`, `curl`, `sha256sum`, `awk`, `sed`, `tar` on the host, a Docker
daemon that can run `linux/riscv64` containers (binfmt handlers: `docker run
--privileged --rm tonistiigi/binfmt --install riscv64`), and optionally `skopeo`
for the image tar check. It checks all of this and says what to install.

`build.sh` now sets `BUILDX_BUILDER=default` unless the environment already set
it. Both image builds use `--load` and then talk to the host daemon's image
store, so they want the plain docker driver; a `docker-container` buildx builder
left selected in the environment fails with `invalid mount config for type
"bind"` on the build context, an error that names neither buildx nor the
builder. This cost a while to find.

No sudo anywhere: everything that needs root (extracting the rootfs, `mknod` for
`/dev/console`, building the cpio with correct ownership) happens inside
containers, and the artifacts are chowned back at the end.

Environment: `WORK_DIR` (scratch, default `$HOME/xen-domu-build/initrd`, put it
on a real filesystem, not a 5 GB tmpfs), `OUT_DIR`, `VARIANT`, `STRIP`,
`SKIP_VERIFY`, `KEEP_IMAGES`, `NO_CACHE`, `SOURCE_DATE_EPOCH`.

Steps: download and verify, amd64 tools image (cross binutils, cpio, zstd), strip
the Go binaries, pull and save the riscv64 images, build the riscv64 rootfs image
(apt, the trim, then the K3s unpack, all emulated), offline checks, then per
variant: `docker export` the image, prune what this variant does not carry, add
`/dev` nodes and the image tars, write the sentinel and the manifest, and
`cpio -o -H newc --reproducible | gzip -9 -n`.

Images the build pulls into the host daemon are removed afterwards unless they
were already there (`KEEP_IMAGES=1` keeps them).

Reproducibility: the cpio is built from a sorted file list with `--reproducible`
and gzipped with `-n`, so two builds of the same inputs give the same archive.
`SOURCE_DATE_EPOCH` pins the build epoch that goes into
`/etc/payload-build-epoch` and the sentinel; without it the archive differs
between runs by that timestamp. The release assets are pinned by sha256. Two
inputs are not: the Debian packages, which move with the trixie archive, and
`hello-world:latest`, which is a moving tag rather than a version. A rebuild
weeks later will pick up newer Debian packages, and will pick up a newer
hello-world if one is published.

### Timings

Host: x86_64 WSL2, 20 cores, 31 GB RAM. **Every riscv64 step is emulated**, the
build steps under qemu-user in Docker and the boots under QEMU TCG. None of this
is native riscv64, and the gap is large enough that these numbers say nothing
about how long the same work takes on hardware.

Build, one invocation producing all four variants, wall clock:

| Step | Wall |
|---|---|
| download release assets (cached after the first run) | 0 s |
| build the amd64 tools image | 1 s |
| strip the Go binaries | 2 s |
| pull and save the riscv64 images (cached) | 0 s |
| build the riscv64 rootfs image (apt, trim, K3s unpack, emulated) | 85 s |
| offline checks (emulated) | 11 s |
| assemble `docker` (cpio, `gzip -9`, `zstd -19`) | 69 s |
| assemble `k3s` | 94 s |
| assemble `all` | 185 s |
| assemble `full` | 204 s |
| **total** | **652 s (10m53s)**, 4.6 s user and 8.5 s sys in the calling shell |

Almost all of that wall time is the Docker daemon's, which is why the shell's
own user and sys times are meaningless here. With a cold layer cache the rootfs
image step is about 95 s longer, because the emulated `apt-get install` runs for
real.

Boots, wall clock, and note that several ran while another build was using the
other cores, so these are upper bounds rather than clean measurements:

| Boot | Wall |
|---|---|
| `docker`, `test=docker`, above the floor | 36 to 40 s |
| `docker`, truncated (the guard stops it) | 7 to 8 s |
| `k3s`, `test=k3s`, at 1024 MiB | 120 and 141 s |
| `all`, `test=all`, at 1280 MiB | 161 and 204 s |
| `full`, `test=k3s`, at 1728 MiB | 118 s |
| `full`, `test=docker`, at 2048 MiB | 51 s |

The integrity check itself is 0 to 2 s of that on every variant.

The old version of this file reported a `test=all` boot taking 375 s of guest
time on the combined image. The comparable boot here, `all` at `-m 1280`, is
161 s of wall clock. Most of that difference is the host being less busy, not
the payload being faster; the one real saving is that `test=docker` no longer
unpacks and then deletes 278 MiB of K3s.

## Things to watch for

- **`PAYLOAD_FAIL: initrd truncated`** means the guest is too small for this
  variant, or the archive on disk is damaged. Check the rootfs line printed two
  lines above it: if "total" is about half of `MemTotal` and "free" is 0, it is
  the tmpfs cap and the guest needs more RAM, a smaller variant, or
  `initramfs_options=size=90%`.
- **`net: no real interface; falling back to dummy0`** on a guest that was
  given a PV or virtio NIC means the interface never appeared. Look at the
  kernel log for the frontend, not at the payload: the payload only reports
  what is in `/sys/class/net`.
- **`net: WARNING no real interface and cannot create dummy0`** means the
  kernel has no `CONFIG_DUMMY` either. K3s will then fail with no default
  route, and the Docker test will still pass.
- **`disk: nothing at /dev/xvda, skipping`** on a guest that was given a PV
  disk means blkfront did not attach. The line after it lists what the kernel
  does have, which is the quickest way to tell a missing driver from a wrong
  `disk.dev=`.
- **`DISK_FAIL: raw write ... failed`** is usually a read-only or
  wrongly-sized device rather than a driver fault; the payload prints
  `/proc/partitions` and the kernel's own block lines under it.
- **`docker: overlayfs is NOT available`** means overlay on tmpfs did not work;
  the run continues on `native`/`vfs`, much slower and hungrier, and that line is
  the explanation for any later disk-space trouble.
- **`DOCKER_FAIL: seccomp filter not applied`** is the interesting failure: the
  container ran but the filter did not install. Check the kernel's
  `CONFIG_SECCOMP_FILTER` before suspecting runc.
- **A long silence with no progress lines** should not happen: `progress=` lines
  come every 30 s by default while waiting. If they stop, look for
  `Out of memory` from the kernel in the console log.
- **K3s image import** happens at agent start and is the slowest part of the K3s
  test after emulation; progress lines show the k3s log line for that.
- The **`-dev` CLI releases** in `docker-for-riscv64` are deliberately not used;
  `cli-v29.8.0-riscv64` matches the engine version.

## Checks that were run

Offline, in a riscv64 container built from the same image the initrds come from:

- every binary runs and reports its version (`dockerd`, `docker`, `containerd`,
  `runc`, `k3s`, `kubectl`);
- `runc --version` prints `libseccomp: 2.6.0`, and the build fails if it does
  not;
- the unpacked K3s tree verifies against its own `.sha256sums`;
- every userland command `/init` uses is present **and starts**: `bash tar cp
  switch_root mountpoint setsid dmesg ip iptables free sysctl busybox awk df
  date timeout find sha256sum stat sed grep du rm mkdir sleep dd od head
  blockdev mount umount readlink basename`. `iptables` is only checked as far
  as the dynamic loader, because it cannot initialize nft inside the build
  container;
- busybox has the `mke2fs` and `mkdosfs` applets the disk test needs. A missing
  applet would otherwise only show up at boot, on a guest that has a disk, as a
  `DISK_FAIL`;
- `docker-proxy` and `docker-init` are absent;
- `bash -n` on `/init`, on the host and again inside the image;
- `skopeo inspect docker-archive:` on every image tar: all report
  `riscv64 linux`.

## Not verified

- Nothing here has run under Xen. It was tested on `qemu-system-riscv64 -M virt`
  only, without Xen, on the part A kernel. A dom0less domU differs: no RTC, a
  device tree written by Xen, memory carved out by the hypervisor.
- **Neither netfront nor blkfront has been exercised here.** Not because the
  frontends do not exist: they do, in the domU kernel, which is a different
  kernel from the one in this directory; see "Two kernels, and which is which"
  above. The kernel shipped beside this payload cannot reach them, so the two
  boots above exercise the **payload's** code for a real interface and a real
  block device, standing in with virtio-net and virtio-blk. That is the right
  substitute and it is not the same claim: what is proven is this code, not
  netfront and not blkfront.
- The vfat fallback in the disk test has never been taken: `busybox mke2fs`
  plus the ext4 driver worked on the first attempt on every boot.
- The disk test has only ever seen a 64 or 128 MiB virtio-blk device backed by
  a file. No partition table, no large device, no slow device.
- The `K3S_OK` negative control was run against the previous `init`, before the
  network and disk changes. That gate's code is byte-identical in this one, but
  the boot was not repeated.
- `k3s.full=1` (traefik, servicelb and metrics-server actually coming up on the
  `full` variant) was never exercised end to end.
- The `docker.storage=` override and the `vfs`/`native` fallback path were never
  exercised, because the overlayfs probe passed on every boot.
- `root.size=` was left at its default on every boot.
- The zstd archives were never booted.
- The K3s pre-unpack means the payload runs `k3s` the way the upstream
  `rancher/k3s` image does, not the way the released stub binary does. The
  difference is only which binary is invoked, but our hardware smoke test of
  this release used the stub.
- The guard cannot detect a file whose content changed without its size
  changing, and nothing here tested that case.
- The RAM floors were not re-bisected after both tests moved to `hello-world`;
  see the note above that table for the size delta the carry-over rests on.
- On the shipped files only the `docker` and `all` variants were booted. The
  `k3s` variant was booted only as the K3s negative control, which fails on
  purpose, and `full` was not booted at all.
- Each of the two passing boots was run once, not repeated.
- The `full` variant's floor was bisected for `test=k3s` only; `test=all` and
  `test=docker` on `full` were not bisected.
