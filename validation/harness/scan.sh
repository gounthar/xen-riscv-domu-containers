#!/bin/bash
# scan.sh <test> <marker> <append-extra> <mem...>
# Boots the payload at each RAM size in turn, descending, and stops at the first
# size that does not reach its marker cleanly.
set -u
BOOTDIR=$(cd "$(dirname "$0")" && pwd)
t=$1; marker=$2; extra=$3; shift 3
for m in "$@"; do
	tag="$t-$m"
	"$BOOTDIR/run-boot.sh" "$tag" "$m" "test=$t $extra" >/dev/null 2>&1
	rc=$?
	python3 "$BOOTDIR/analyse.py" "$BOOTDIR/logs/$tag.log"
	python3 - "$BOOTDIR/logs/$tag.log" "$marker" "$rc" <<'PY'
import sys
from pathlib import Path
lines=[l.rstrip('\r\n').strip() for l in Path(sys.argv[1]).read_text(errors='replace').splitlines()]
ok = lines.count(sys.argv[2])==1 and lines.count('PAYLOAD_DONE')==1 and sys.argv[3]=='0'
print('VERDICT: PASS' if ok else 'VERDICT: FAIL')
sys.exit(0 if ok else 1)
PY
	[ $? -eq 0 ] || { echo "$tag: floor crossed, stopping"; break; }
done
