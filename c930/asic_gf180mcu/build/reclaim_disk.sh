#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# reclaim_disk.sh -- free space on the flow box after the GRT_ADJUSTMENT sweep.
#
# /home was at 89 % (17 GB free) with the next flow run still to come. Every
# item below is re-verified at run time and nothing is removed on an unverified
# assumption -- the duplicate check runs first, and a copy that does not cmp
# clean is KEPT with a complaint.
#
#   DRY=1 bash build/reclaim_disk.sh     # print the plan, change nothing
#   bash build/reclaim_disk.sh           # do it
#
# WHAT GOES, AND WHY IT IS SAFE
#
#   * drt_fast/ckpt/{pre_drt_slotcore,pre_drt_slotcore03,pre_drt_sweep0.1,
#     pre_drt_sweep0.2}.odb -- byte-identical copies (cmp) of the pre-DRT ODB
#     that each arm's flow step already wrote under runs/slotcore_v1. The
#     original is what a resume reads; the copy existed only so the fast-DRT
#     driver has a stable filename. A map is written to
#     drt_fast/ckpt/WHERE_ARE_THE_CHECKPOINTS.md BEFORE anything is deleted, so
#     the 0.2-vs-0.3 falsifier run can still be pointed at its input.
#   * drt_fast/ckpt/pre_drt.odb (fat core) -- byte-identical copy of the v8
#     run's 41-openroad-repairantennas/1-diodeinsertion ODB.
#   * drt_fast/out/*/*.odb and *.drc, and ckpt/pre_drt.def / after_grt.guide --
#     NOT deleted: zstd'd in place. The fast-DRT outputs are the routed results
#     and the DRC reports are the violation-anatomy source, so the data is kept
#     and only the disk cost is removed. `zstd -d` to read one back.
#     out/ is root-owned (the DRT runs write as --user 0:0) and neither image
#     ships zstd, so step 1b hands the tree back to the host user with chown run
#     as root inside a container, and only then compresses on the host.
#   * openroad/ubuntu24.04:latest (11.3 GB) -- the router-version A/B is closed
#     (DRT_fastloop_status.md sec.8: 26Q3 is 5-6 % worse at every checkpoint,
#     never better; newor2's log is kept at drt_fast/logs/newor2.log). Nothing
#     references it. Re-pullable.
#   * ws_synth container (3.9 GB layer) -- the ws_synth2 retry inside it has
#     finished and its evidence is on the host
#     (ws/logs/ws_synth.ws_synth2.log, ws/logs/netlist_compare.ws_synth2.txt).
#     The layer is a per-container /nix store, and build/ws_synth_chain.sh
#     throws it away with `docker rm -f ws_synth` before every run anyway --
#     it is not a cache. The next ws run re-populates it from the network.
#
# WHAT IS DELIBERATELY NOT TOUCHED
#
#   * runs/RUN_2026-09-30_23-41-23 -- the active v8 run, 4.7 GB, named as
#     off-limits by compress_old_run.py's own policy.
#   * runs/slotcore_v1 -- the live tapeout run the next step resumes from.
#   * the Sept 22-23 campaign runs -- already zstd'd by compress_old_run.py.
#   * ghcr.io/wafer-space/gf180mcu-precheck -- the wafer.space flow environment.
#   * ghcr.io/efabless/openlane2:2.3.10 -- the OL2/DRT environment.
#   * docker volumes wrenai_*/legibleai_*/wren_* (5.5 GB) -- another project's
#     data, not ours to remove.
set -u
D=/home/ubuntu/grx930_ol2/drt_fast
R=/home/ubuntu/grx930_ol2/openlane2_rtl/runs/slotcore_v1
V8=/home/ubuntu/grx930_ol2/openlane2_rtl/runs/RUN_2026-09-30_23-41-23
DRY=${DRY:-0}
rm_it() {  # rm_it <path> <reason>
  [ -e "$1" ] || { echo "  skip (absent): $1"; return; }
  local sz; sz=$(du -sh "$1" 2>/dev/null | cut -f1)
  if [ "$DRY" = 1 ]; then echo "  WOULD REMOVE $sz  $1   -- $2"; return; fi
  rm -rf -- "$1" && echo "  removed $sz  $1   -- $2"
}
z_it() {   # z_it <file> -- zstd in place, verify, keep the original on any failure
  [ -f "$1" ] || { echo "  skip (absent): $1"; return; }
  case $1 in *.zst) echo "  skip (already zstd): $1"; return;; esac
  local a b
  if [ ! -w "$(dirname "$1")" ]; then
    echo "  SKIP (root-owned dir -- step 1b did not run): $1"; return 1
  fi
  a=$(stat -c %s "$1")
  if [ "$DRY" = 1 ]; then echo "  WOULD ZSTD $((a/1000000)) MB  $1"; return; fi
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
    "$(awk -v x=$a -v y=$b 'BEGIN{printf "%.1f", x/y}')" "$1"
}

echo "=== BEFORE ==="; df -h / | tail -1; du -sh "$D" "$D/out" "$D/ckpt" 2>/dev/null
echo

echo "=== keep-map (written first, so the falsifier run still has its inputs) ==="
if [ "$DRY" = 1 ]; then
  echo "  WOULD WRITE $D/ckpt/WHERE_ARE_THE_CHECKPOINTS.md"
else
cat > "$D/ckpt/WHERE_ARE_THE_CHECKPOINTS.md" <<'EOF'
# Where the pre-DRT checkpoints live

The four `pre_drt_*.odb` files this directory used to hold were byte-identical
copies of flow-step outputs and were removed to reclaim disk. The originals are
still in the run tree; point `FAST_ODB` at these paths:

| GRT adj | checkpoint (freed from here) | original, in the run tree |
|---|---|---|
| 0.0 | pre_drt_slotcore.odb (194.4 MiB) | runs/slotcore_v1/41-openroad-repairantennas/1-diodeinsertion/grx930_test_chip.odb |
| 0.3 | pre_drt_slotcore03.odb (209.5 MiB) | runs/slotcore_v1/45-openroad-repairantennas/1-diodeinsertion/grx930_test_chip.odb |
| 0.1 | pre_drt_sweep0.1.odb (201.2 MiB) | runs/slotcore_v1/49-openroad-repairantennas/1-diodeinsertion/grx930_test_chip.odb |
| 0.2 | pre_drt_sweep0.2.odb (202.2 MiB) | runs/slotcore_v1/53-openroad-repairantennas/1-diodeinsertion/grx930_test_chip.odb |

The fat-core `pre_drt.odb` was a copy of
`RUN_2026-09-30_23-41-23/41-openroad-repairantennas/1-diodeinsertion/grx930_test_chip.odb`
(byte-identical) and was removed the same way. That layout is abandoned -- the
12.93 mm2 slot core is the tapeout layout.

So the 0.2-vs-0.3 falsifier run needs no re-flow: take step 53's ODB for 0.2 and
step 45's for 0.3.
EOF
echo "  wrote $D/ckpt/WHERE_ARE_THE_CHECKPOINTS.md"
fi
echo

echo "=== 1. duplicate checkpoints (delete only if cmp proves identical) ==="
for pair in "41 pre_drt_slotcore" "45 pre_drt_slotcore03" "49 pre_drt_sweep0.1" "53 pre_drt_sweep0.2"; do
  set -- $pair
  o=$R/$1-openroad-repairantennas/1-diodeinsertion/grx930_test_chip.odb
  c=$D/ckpt/$2.odb
  if [ ! -f "$c" ]; then echo "  skip (absent): $c"; continue; fi
  if [ -f "$o" ] && cmp -s "$o" "$c"; then
    rm_it "$c" "byte-identical to step $1"
  else
    echo "  KEPT $c -- NOT identical to $o (or origin missing); not safe to remove"
  fi
done
if [ -f "$D/ckpt/pre_drt.odb" ]; then
  if cmp -s "$D/ckpt/pre_drt.odb" "$V8/41-openroad-repairantennas/1-diodeinsertion/grx930_test_chip.odb"; then
    rm_it "$D/ckpt/pre_drt.odb" "byte-identical to the v8 run's step 41 (fat core, abandoned)"
  else
    echo "  KEPT $D/ckpt/pre_drt.odb -- not identical to the v8 step 41; not safe to remove"
  fi
fi
echo

echo "=== 1b. container-owned results back to the host user (root inside a container) ==="
# out/ is written by the DRT runs as --user 0:0, so the host user cannot write
# beside those files and zstd fails (measured: every out/ file failed closed on
# the first run of this script). Neither image ships zstd, but both ship chown,
# so ownership is handed over here and the compression below runs on the host,
# where zstd exists and every archive can be verified. Same constraint
# compress_old_run.py documents: "run as root inside the openlane container".
OL2IMG=ghcr.io/efabless/openlane2:2.3.10
FIXED=0
for d in "$D"/out; do
  [ -w "$d" ] && continue
  FIXED=1
  if [ "$DRY" = 1 ]; then echo "  WOULD chown -R $(id -u):$(id -g) $d (as root via $OL2IMG)"; continue; fi
  docker run --rm --user 0:0 -v /home/ubuntu/grx930_ol2:/work "$OL2IMG" \
    bash -c "chown -R $(id -u):$(id -g) /work/drt_fast/out" \
    && echo "  chowned -R $(id -u):$(id -g) $d" \
    || echo "  FAILED to chown $d"
done
[ "$FIXED" = 0 ] && echo "  nothing to fix (already host-writable)"
echo

echo "=== 2. compress the results that are worth keeping ==="
for f in "$D"/out/*/*.odb "$D"/out/*/*.drc "$D"/ckpt/pre_drt.def "$D"/ckpt/after_grt.guide; do
  [ -f "$f" ] && z_it "$f"
done
echo

echo "=== 3. the spent router-ab image, the unused base, the finished container ==="
if docker image inspect openroad/ubuntu24.04:latest >/dev/null 2>&1; then
  if [ "$DRY" = 1 ]; then echo "  WOULD REMOVE openroad/ubuntu24.04:latest (11.3 GB)"
  else docker rmi openroad/ubuntu24.04:latest >/dev/null 2>&1 \
        && echo "  removed openroad/ubuntu24.04:latest (11.3 GB)" \
        || echo "  FAILED to remove openroad/ubuntu24.04:latest (still referenced?)"; fi
fi
if docker image inspect ubuntu:22.04 >/dev/null 2>&1; then
  if [ "$DRY" = 1 ]; then echo "  WOULD REMOVE ubuntu:22.04 (119 MB)"
  else docker rmi ubuntu:22.04 >/dev/null 2>&1 \
        && echo "  removed ubuntu:22.04 (119 MB)" \
        || echo "  KEPT ubuntu:22.04 -- still referenced"; fi
fi
if docker container inspect ws_synth >/dev/null 2>&1; then
  if [ "$DRY" = 1 ]; then echo "  WOULD REMOVE container ws_synth (3.9 GB layer)"
  else
    docker logs ws_synth > /home/ubuntu/grx930_ol2/ws/logs/ws_synth.final.log 2>&1
    docker rm ws_synth >/dev/null 2>&1 && echo "  removed container ws_synth (3.9 GB layer; log re-dumped to ws/logs/ws_synth.final.log)" \
      || echo "  FAILED to remove container ws_synth"
  fi
fi
echo

echo "=== AFTER ==="; df -h / | tail -1
du -sh "$D" "$D/out" "$D/ckpt" 2>/dev/null
docker system df | tail -5
echo
echo "=== surviving artifacts check ==="
ls -l "$D/ckpt/" | sed 's/^/  /'
echo "  zstd files in out/: $(find "$D/out" -name '*.zst' | wc -l)"
echo "  images now:"; docker images --format "    {{.Repository}}:{{.Tag}} {{.Size}}" 
echo "  containers now:"; docker ps -a --format "    {{.Names}} {{.Status}}"
