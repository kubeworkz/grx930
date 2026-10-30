#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# compress_old_run.sh -- second pass: finish archiving the OLD campaign run.
#
# The run is the Sept-24 campaign (RUN_2026-09-24_04-18-20), which lives on the
# Hetzner volume at /mnt/HC_Volume_106967865. It is evidence, not garbage:
# PLAN_B_netlist_rework.md cites its 06-yosys-synthesis/reports/stat.rpt and
# 52-openroad-globalrouting/state_out.json, and run_v3*.sh resume it. So it is
# archived in place, never deleted.
#
#   DRY=1 bash compress_old_run.sh     # print the plan
#   bash compress_old_run.sh           # do it
#
# PASS HISTORY
#
#   pass 1 (compress_old_run.sh, container-side): zstd'd *.odb / *.guide / *.log
#     over 10 MB -- 34 archives. That left the text artifacts, which are the bulk
#     of what remains: the JSON netlist (340 MB), three SDF timing files (296 MB
#     each), the ABC techmap dot (175 MB), DEFs (132 MB), pnl.v (125 MB).
#   compress_old_run.py did the same job for the Sept 22-23 pre-campaign runs.
#   pass 2 (this script): everything >10 MB that is not already *.zst / *.gz.
#
# WHY THIS RUNS ON THE HOST AND NOT IN THE CONTAINER
#
#   The files are root-owned on a root-owned mount, so the host user cannot write
#   beside them -- but neither flow image ships zstd (measured: `zstd MISSING` in
#   openlane2:2.3.10 and in gf180mcu-precheck; both ship chown). So this does what
#   build/reclaim_disk.sh does: hand the tree to the host user with chown run as
#   root inside a container, then compress on the host, where zstd exists and every
#   archive can be verified. If a compression fails, the original is kept.
#
# NEVER TOUCHED: runs/slotcore_v1 (the live tapeout run), RUN_2026-09-30_23-41-23
# (the active v8 run -- off-limits by policy), the swapfile, lost+found, and
# anything already compressed.
set -u
VOL=/mnt/HC_Volume_106967865
R=$VOL/RUN_2026-09-24_04-18-20
OL2IMG=ghcr.io/efabless/openlane2:2.3.10
MIN=10M
DRY=${DRY:-0}

[ -d "$R" ] || { echo "no such run: $R"; exit 1; }

z_it() {   # z_it <file> -- zstd in place, verify, keep the original on failure
  [ -f "$1" ] || return
  case $1 in *.zst|*.gz) return;; esac
  local a b
  # In DRY mode phase 1 has not run, so every file is still root-owned; that is
  # not a plan blocker, it is the thing phase 1 would fix. Only gate on it live.
  if [ "$DRY" != 1 ] && [ ! -w "$(dirname "$1")" ]; then
    echo "  SKIP (not writable -- chown phase did not cover it): $1"; return 1
  fi
  a=$(stat -c %s "$1")
  if [ "$DRY" = 1 ]; then echo "  WOULD ZSTD $((a/1000000)) MB  ${1#$R/}"; return; fi
  if ! zstd -q -f -T2 --rm -- "$1"; then
    echo "  FAILED to compress (kept as-is): $1"; rm -f "$1.zst"; return 1
  fi
  if ! zstd -t -q -- "$1.zst" 2>/dev/null; then
    echo "  FAILED verify -> restoring: $1"
    zstd -d -q -f --rm -- "$1.zst" || echo "    !! restore failed; data is still in $1.zst"
    return 1
  fi
  b=$(stat -c %s "$1.zst")
  printf '  zstd %5d -> %4d MB (%.1fx)  %s\n' "$((a/1000000))" "$((b/1000000))" \
    "$(awk -v x=$a -v y=$b 'BEGIN{printf "%.1f", x/y}')" "${1#$R/}"
}

echo "=== BEFORE ==="
df -h "$VOL" | tail -1; du -sh "$R"
echo "  already compressed: $(find "$R" -name '*.zst' -o -name '*.gz' | wc -l) archives"
echo
echo "=== paths the docs cite must stay readable (they are small, so pass 2 skips them) ==="
for f in "$R/06-yosys-synthesis/reports/stat.rpt" "$R/52-openroad-globalrouting/state_out.json"; do
  if [ -f "$f" ]; then printf '  %8d B  %s  (%s)\n' "$(stat -c %s "$f")" "${f#$R/}" \
    "$([ "$(stat -c %s "$f")" -ge 10485760 ] && echo 'WILL BE COMPRESSED' || echo 'untouched')"
  else echo "  absent: ${f#$R/}"; fi
done
echo

echo "=== phase 1: hand the root-owned tree to the host user (chown as root in a container) ==="
if [ -w "$R" ]; then
  echo "  already host-writable"
elif [ "$DRY" = 1 ]; then
  echo "  WOULD chown -R $(id -u):$(id -g) $R (via $OL2IMG as root)"
else
  docker run --rm --user 0:0 -v "$VOL:/vol" "$OL2IMG" \
    bash -c "chown -R $(id -u):$(id -g) /vol/RUN_2026-09-24_04-18-20" \
    && echo "  chowned -R $(id -u):$(id -g) $R" || echo "  FAILED to chown"
fi
echo

echo "=== phase 2: compress every remaining bulky file ==="
# Sorted smallest-first so a failure costs the least; all of it is the same job.
find "$R" -type f -size +$MIN -not -name '*.zst' -not -name '*.gz' -printf '%s %p\n' 2>/dev/null \
  | sort -n | cut -d' ' -f2- | while IFS= read -r f; do z_it "$f"; done
echo

echo "=== AFTER ==="
du -sh "$R"; df -h "$VOL" | tail -1
echo "  archives now: $(find "$R" -name '*.zst' -o -name '*.gz' | wc -l)"
echo "  leftover uncompressed >10M: $(find "$R" -type f -size +$MIN -not -name '*.zst' -not -name '*.gz' | wc -l)"
