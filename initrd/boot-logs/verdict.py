#!/usr/bin/env python3
"""Verdict for one payload boot log.

A boot counts as a FAILURE whenever the kernel logged "Initramfs unpacking
failed", no matter which markers were printed: that is exactly how an earlier
round of measurements recorded passes on an image missing a third of its files.
"""
import re, sys
from pathlib import Path

MARKERS = ["PAYLOAD_START", "DOCKER_OK", "K3S_OK", "PAYLOAD_DONE"]

for p in sys.argv[1:]:
    log = Path(p)
    lines = [l.rstrip("\r\n").strip() for l in log.read_text(errors="replace").splitlines()]
    c = {m: lines.count(m) for m in MARKERS}
    trunc = any("Initramfs unpacking failed" in l for l in lines)
    pfail = [l for l in lines if l.startswith("PAYLOAD_FAIL:")]
    dfail = [l for l in lines if l.startswith("DOCKER_FAIL:")]
    kfail = [l for l in lines if l.startswith("K3S_FAIL:")]
    panic = any("Kernel panic" in l for l in lines)
    oom = any(s in l for l in lines for s in ("Out of memory", "oom-kill", "Killed process"))
    peak = 0
    total = 0
    for l in lines:
        m = re.match(r"^Mem:\s+(\d+)\s+(\d+)", l)
        if m:
            total = int(m.group(1))
            peak = max(peak, int(m.group(2)))
    rootfs = next((l for l in lines if "rootfs (initramfs)" in l), "")
    guard = next((l for l in lines if "payload: image intact" in l), "")
    meta = log.with_suffix(".meta")
    mt = dict((k.strip(), v.strip()) for k, _, v in
              (l.partition(":") for l in meta.read_text().splitlines())) if meta.exists() else {}
    want = sys.argv[0]  # unused
    print(f"== {log.name}  mem={mt.get('machine','?').split('-m ')[-1].split()[0] if mt else '?'}"
          f" exit={mt.get('exit','?')} wall={mt.get('wall_s','?')}s")
    print(f"   markers: " + " ".join(f"{m}={c[m]}" for m in MARKERS))
    print(f"   truncated={trunc} panic={panic} oom={oom} peak_used={peak}M of {total}M")
    if rootfs:
        print(f"   {rootfs.split('] ',1)[-1]}")
    if guard:
        print(f"   {guard.split('] ',1)[-1]}")
    for l in pfail + dfail + kfail:
        print(f"   {l}")
