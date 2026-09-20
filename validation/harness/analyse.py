#!/usr/bin/env python3
"""Summarise a payload boot log. Serial console lines end with CR, so every
line is stripped before matching; a marker only counts when it is the whole
line, which is what separates init's own marker from a marker quoted inside a
failure message."""

import re
import sys
from pathlib import Path

MARKERS = ["PAYLOAD_START", "DOCKER_OK", "K3S_OK", "PAYLOAD_DONE"]


def summarise(log: Path) -> dict:
    lines = [l.rstrip("\r\n") for l in log.read_text(errors="replace").splitlines()]
    out = {m: sum(1 for l in lines if l.strip() == m) for m in MARKERS}
    out["DOCKER_FAIL"] = sum(1 for l in lines if l.startswith("DOCKER_FAIL:"))
    out["K3S_FAIL"] = sum(1 for l in lines if l.startswith("K3S_FAIL:"))

    peak = 0
    for l in lines:
        m = re.match(r"^Mem:\s+(\d+)\s+(\d+)", l)
        if m:
            peak = max(peak, int(m.group(2)))
    out["peak_used_MiB"] = peak
    out["mem_total_MiB"] = next(
        (int(m.group(1)) for l in lines if (m := re.match(r"^Mem:\s+(\d+)", l))), 0
    )

    out["summary"] = next(
        (l.split("SUMMARY:", 1)[1].strip() for l in lines if "SUMMARY:" in l), ""
    )
    out["poweroff"] = any("reboot: Power down" in l for l in lines)
    out["oom"] = any(
        s in l
        for l in lines
        for s in ("Out of memory", "oom-kill", "Killed process", "Kernel panic")
    )
    out["seccomp_mode"] = next(
        (l.split()[1] for l in lines if l.startswith("Seccomp:")), ""
    )
    out["seccomp_filters"] = next(
        (l.split()[1] for l in lines if l.startswith("Seccomp_filters:")), ""
    )
    out["k3s_version"] = next(
        (l.split("k3s: ", 1)[1] for l in lines if "] k3s: k3s version" in l), ""
    )
    out["node_line"] = next(
        (l.split("k3s: ", 1)[1] for l in lines if re.search(r"k3s: domu\s+Ready", l)),
        "",
    )
    return out


for p in sys.argv[1:]:
    log = Path(p)
    s = summarise(log)
    meta = log.with_suffix(".meta")
    mt = (
        dict(
            (k.strip(), v.strip())
            for k, _, v in (l.partition(":") for l in meta.read_text().splitlines())
        )
        if meta.exists()
        else {}
    )
    print(f"== {log.name}")
    print(f"   mem={mt.get('machine', '?')}")
    print(f"   append={mt.get('append', '?')}")
    print(f"   qemu exit={mt.get('exit', '?')} wall={mt.get('wall_s', '?')}s")
    print(
        "   markers: "
        + " ".join(f"{m}={s[m]}" for m in MARKERS)
        + f" DOCKER_FAIL={s['DOCKER_FAIL']} K3S_FAIL={s['K3S_FAIL']}"
    )
    print(f"   SUMMARY: {s['summary']}")
    print(
        f"   peak used={s['peak_used_MiB']}M of {s['mem_total_MiB']}M"
        f"  poweroff={s['poweroff']}  oom/panic={s['oom']}"
    )
    if s["seccomp_mode"]:
        print(
            f"   seccomp: Seccomp={s['seccomp_mode']} Seccomp_filters={s['seccomp_filters']}"
        )
    if s["k3s_version"]:
        print(f"   {s['k3s_version']}")
    if s["node_line"]:
        print(f"   node: {s['node_line']}")
