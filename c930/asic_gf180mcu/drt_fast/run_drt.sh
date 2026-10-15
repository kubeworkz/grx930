#!/bin/bash
# Fast DRT-only experiment runner. Runs inside the openlane2 image with the
# workspace bind-mounted at /work. Uses only bash builtins so it does not depend
# on what the image places on PATH (sed, ls, mkdir etc. are not all present).
set -u

D=/work/drt_fast
export FAST_TAG=${FAST_TAG:-exp1}
export FAST_ODB=${FAST_ODB:-$D/ckpt/pre_drt.odb}
export FAST_OUT=${FAST_OUT:-$D/out/$FAST_TAG}
export FAST_THREADS=${FAST_THREADS:-8}
export FAST_END_ITER=${FAST_END_ITER:-2}
export FAST_MIN_LAYER=${FAST_MIN_LAYER:-Metal1}
export FAST_MAX_LAYER=${FAST_MAX_LAYER:-Metal5}

printf 'RUN_START %(%Y-%m-%dT%H:%M:%SZ)T tag=%s odb=%s iter=%s layers=%s-%s threads=%s\n' \
    -1 "$FAST_TAG" "$FAST_ODB" "$FAST_END_ITER" "$FAST_MIN_LAYER" "$FAST_MAX_LAYER" "$FAST_THREADS"

OR=${FAST_OPENROAD:-/nix/store/zzypcxbrgw1qink1l7fwgwpbk7fvdwpg-openroad/bin/openroad}
"$OR" -exit -no_splash "$D/drt_fast.tcl"
rc=$?
printf 'RUN_END %(%Y-%m-%dT%H:%M:%SZ)T rc=%s\n' -1 "$rc"
exit $rc
