#!/bin/sh
# probe_grt.sh -- container side: rerun ONLY OpenROAD.GlobalRouting against a
# frozen run's own pre-GRT state, with GRT knobs read from the staged config (or
# overridden one arm at a time), so a wrong knob costs ~7 minutes instead of a
# 3-hour flow.
#
# Same shape as probe_step31.sh: LibreLane's --only machinery takes an explicit
# initial state file, and a failed step's own `state_in.json` is exactly the
# state it was given, so nothing upstream is redone -- same input ODB, same step,
# new knobs. The probe writes into a FRESH run tag, so the run it is diagnosing
# is only ever read.
#
# Why this instrument exists: `[ERROR GRT-0183] Net <name>: heap underflow
# during 3D maze routing` is not a violated constraint, it is the maze router
# finding no legal path within the search region for one edge during the
# overflow-removal loop (OpenROAD PR #10711's comment: "no path could be found
# within the search region"). Which configuration reaches that state is a
# measurement, not a reading of the message -- this is the instrument that made
# it, and it is the instrument that re-checks it whenever the config changes.
#
#   PROBE_TAG        fresh tag for the probe tree (default grt_probe_<knob>)
#   PROBE_STATE_TAG  run whose GRT step state to start from (default ws_v3)
#   PROBE_STATE_STEP step directory (default 37-openroad-globalrouting)
#
#   GRT_ADJUSTMENT / GRT_OVERFLOW_ITERS / GRT_LAYER_ADJUSTMENTS
#       optional. Set any of them to test that one knob instead of what the
#       staged overrides say; the overlay is written next to the template's own
#       configs because `dir::` references resolve against the *last* config
#       file's directory, and one living elsewhere breaks every MACROS path.
#
# Set GRT_LAYER_ADJUSTMENTS as a YAML list ("[-0.2, 0, 0, 0, 0]"): the string
# form is refused with "Refusing to automatically convert ... to list".
#
#   docker run --rm --user 0:0 -v /home/ubuntu/grx930_ol2:/work \
#       -e PROBE_TAG=grt_probe_it1 -e GRT_OVERFLOW_ITERS=1 \
#       ghcr.io/wafer-space/gf180mcu-precheck /work/ws/probe_grt.sh
#
# Measured with it (2026-10-13, ws_v3 step 37, each arm ~7 min / 3 GiB / 1 thread):
#
#   arm                            iterations  final overflow      GRT-0115
#   ws_v3 as-is (GRT_ADJUSTMENT .2)   abort at 14 (net21814, deterministic)
#   GRT_ADJUSTMENT 0.1                8         0 on every layer       no
#   GRT_ADJUSTMENT 0.15              12         18 (M2 2, M4 16)       yes
#   GRT_OVERFLOW_ITERS 1              1         63,525 (M2 47,168)     yes
#   GRT_LAYER_ADJUSTMENTS [-.2,0,0,0,0], 0.2 kept
#                                    13         7                      yes
#
# The last row keeps M2-M5 byte-identical to the 0.2 arms and gives Metal1 +52 %
# (709,799 -> 1,080,188) and still completes, which is how Metal1 was ruled out
# as the binding layer (its usage is 7.6-8.6 %, Metal2 is at 59-61 %).
set -u
cd /work/ws/template || exit 1

STATE=/work/ws/template/librelane/runs/${PROBE_STATE_TAG:-ws_v3}/${PROBE_STATE_STEP:-37-openroad-globalrouting}/state_in.json
[ -f "$STATE" ] || { echo "PROBE: no state at $STATE" >&2; exit 1; }

# The overlay is rebuilt from scratch every run, and removed outright when no
# knob was asked for: a stale one would silently become the arm, and an EMPTY or
# comment-only YAML file is refused by LibreLane ("'NoneType' object has no
# attribute 'get'") -- so it is only ever passed when it has real content.
TAG=${PROBE_TAG:-grt_probe}
OVERLAY=librelane/grt_probe_overlay.yaml
rm -f "$OVERLAY"
if [ -n "${GRT_ADJUSTMENT:-}" ]; then
    printf 'GRT_ADJUSTMENT: %s\n' "$GRT_ADJUSTMENT" >> "$OVERLAY"
fi
if [ -n "${GRT_OVERFLOW_ITERS:-}" ]; then
    printf 'GRT_OVERFLOW_ITERS: %s\n' "$GRT_OVERFLOW_ITERS" >> "$OVERLAY"
fi
if [ -n "${GRT_LAYER_ADJUSTMENTS:-}" ]; then
    printf 'GRT_LAYER_ADJUSTMENTS: %s\n' "$GRT_LAYER_ADJUSTMENTS" >> "$OVERLAY"
fi
OVERLAY_ARG=""
[ -s "$OVERLAY" ] && OVERLAY_ARG="$OVERLAY"

echo "PROBE: tag=$TAG state=$STATE"
echo "PROBE: librelane $(librelane --version 2>&1 | head -1)"
echo "PROBE: GRT knobs as the flow will resolve them --"
grep -nE "^GRT_(ADJUSTMENT|OVERFLOW_ITERS|LAYER_ADJUSTMENTS|ALLOW_CONGESTION):" \
    librelane/grx930_overrides.yaml "$OVERLAY" 2>/dev/null
if [ -n "$OVERLAY_ARG" ]; then
    echo "PROBE: overlay (overrides the lines above) --"; cat "$OVERLAY"
else
    echo "PROBE: no overlay -- the staged overrides are the arm"
fi

librelane --pdk gf180mcuD --pdk-root "${PDK_ROOT:-/workspace/gf180mcu}" \
    --manual-pdk --scl gf180mcu_fd_sc_mcu7t5v0 --pad gf180mcu_fd_io \
    --run-tag "$TAG" --only OpenROAD.GlobalRouting --overwrite \
    -i "$STATE" \
    librelane/slots/slot_1x1.yaml \
    librelane/macros/macros_grx930.yaml \
    librelane/config.yaml \
    librelane/grx930_overrides.yaml \
    $OVERLAY_ARG
rc=$?

# The verdict is read off the step's own log, not off the exit code alone: the
# step also passes when GRT finishes with congestion (GRT-0115 is a warning under
# GRT_ALLOW_CONGESTION), which is a different outcome from converging.
LOG=$(ls -1t librelane/runs/"$TAG"/*-openroad-globalrouting/openroad-globalrouting.log 2>/dev/null | head -1)
echo "PROBE: exit=$rc log=${LOG:-none}"
if [ -n "${LOG:-}" ]; then
    grep -aE "Global adjustment|Start extra iteration|GRT-0183|GRT-0115|Total wirelength" "$LOG" | tail -6
    grep -a -A9 "Final congestion report" "$LOG" | tail -9
fi
echo "PROBE_EXIT:$rc"
exit $rc
