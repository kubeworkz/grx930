#!/bin/sh
# die_drt_exec.sh -- container side: the die's own fast-DRT arm at the landed
# GRT_ADJUSTMENT (0.1). Runs drt_fast/run_drt.sh with FAST_TCL pointed at
# drt_fast/die_drt.tcl: the same protocol the slot-core arms ran (2 iterations,
# -or_seed 42, 8 threads, Metal1-Metal5), with the layer range stated via
# `set_routing_layers` instead of drt_fast.tcl's
# `-bottom_routing_layer/-top_routing_layer` -- because THIS build answers those
# flags with `[ERROR DRT-0509] ... deprecated` and aborts (measured: the first
# die02 arm, 2026-10-13 23:01, rc=1 after 2 s). LibreLane's own drt.tcl
# (scripts/openroad/drt.tcl:85-92) passes no layer flags either: it hands the
# router -droute_end_iter $DRT_OPT_ITERS -or_seed 42 -verbose 1 -output_drc ...,
# and the flow's GPL/GRT scripts state the range with set_routing_layers from
# RT_MIN_LAYER/RT_MAX_LAYER. die_drt.tcl mirrors exactly that, and prints the
# tech's routing layers so the log carries the range as data.
#
# Why this image and not ghcr.io/efabless/openlane2:2.3.10 (which ran the slot
# core arms): the die's pre-DRT ODB is written by THIS image's openroad (LibreLane
# 3.1.0.dev1, the pre-check image the ws flow runs in), and the flow's own
# DetailedRouting step runs this same binary. Reading the database with the build
# that wrote it removes the one confound (an ODB-format/build mismatch) a
# cross-image arm could not rule out.
#
# The one thing this wrapper adds is FAST_OPENROAD: the driver's default path is
# the openlane2 image's nix store, which does not exist here. `openroad` on PATH
# is the binary LibreLane itself resolves in this image.
#
# DIE_DRT_OR picks a DIFFERENT engine for the loop, and exists because a database
# should be routed by the build that wrote it. The pin candidate wrote
# ws/probe/out_pin01/base.odb (ANT_DRIVER 26Q4-407-geb14e40b7b), so routing that
# one with the pinned build is a cross-build read -- a variable worth isolating
# rather than living with: build/drt_db_compare_chain.sh runs the same database
# through both engines for exactly that reason, and the value here is any
# executable, including the wrapper ws/tools/openroad_26q4.sh.
set -u
: "${FAST_ODB:?FAST_ODB must be set}"
OR=$(command -v openroad) || { echo "die_drt: no openroad on PATH" >&2; exit 1; }
[ -n "${DIE_DRT_OR:-}" ] && OR=$DIE_DRT_OR
echo "DIE_DRT: openroad=$OR ($("$OR" -version 2>&1 | head -1))"
echo "DIE_DRT: engine=${DIE_DRT_OR:+override via DIE_DRT_OR}${DIE_DRT_OR:-pinned}"
echo "DIE_DRT: odb=$FAST_ODB tag=${FAST_TAG:-exp1} iter=${FAST_END_ITER:-2} layers=${FAST_MIN_LAYER:-Metal1}-${FAST_MAX_LAYER:-Metal5} threads=${FAST_THREADS:-8}"
export FAST_OPENROAD="$OR"
export FAST_TCL=${FAST_TCL:-/work/drt_fast/die_drt.tcl}
echo "DIE_DRT: tcl=$FAST_TCL"
exec bash /work/drt_fast/run_drt.sh
