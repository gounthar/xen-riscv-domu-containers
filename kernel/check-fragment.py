#!/usr/bin/env python3
"""Check that every symbol in a Kconfig fragment has the requested value in a final .config.

merge_config.sh warns about dropped symbols, but the warning scrolls past and the
exit code stays 0. This makes the result a file you can read and diff.

Usage: check-fragment.py FRAGMENT DOTCONFIG [KERNEL_SRC]

With KERNEL_SRC, each symbol is also looked up in the tree's Kconfig files, so a
misspelt or removed symbol is reported as "no such symbol" rather than "dropped".
Exit status: 0 if every symbol matches, 1 otherwise.
"""

import re
import sys
from pathlib import Path

SET_RE = re.compile(r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$")
UNSET_RE = re.compile(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$")


def parse(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if m := SET_RE.match(line):
            values[m.group(1)] = m.group(2)
        elif m := UNSET_RE.match(line):
            values[m.group(1)] = "n"
    return values


def kconfig_symbols(src: Path) -> set[str]:
    symbols: set[str] = set()
    pattern = re.compile(r"^\s*(?:menu)?config\s+([A-Za-z0-9_]+)\s*$", re.M)
    for kconfig in src.rglob("Kconfig*"):
        if kconfig.is_file():
            symbols.update(pattern.findall(kconfig.read_text(errors="replace")))
    return symbols


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        return 2
    fragment, dotconfig = parse(Path(sys.argv[1])), parse(Path(sys.argv[2]))
    known = kconfig_symbols(Path(sys.argv[3])) if len(sys.argv) == 4 else None

    bad = 0
    for sym, want in fragment.items():
        got = dotconfig.get(sym, "n")
        if known is not None and sym.removeprefix("CONFIG_") not in known:
            status = "NO SUCH SYMBOL"
        elif got == want:
            status = "ok"
        else:
            status = "DROPPED" if got == "n" else "MISMATCH"
        if status != "ok":
            bad += 1
        print(f"{status:15} {sym}  want={want} got={got}")

    print()
    print(
        f"{len(fragment)} symbols in fragment, {len(fragment) - bad} ok, {bad} not as requested"
    )
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
