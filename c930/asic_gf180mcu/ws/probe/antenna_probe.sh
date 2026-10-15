#!/bin/sh
# antenna_probe.sh -- container side: try the antenna repair's own argument list,
# one variant per OpenROAD process, against the die's pre-repair database.
#
# Why this can answer the question the flow cannot: in the flow the abort is fatal,
# so a variant costs a full resume (~30 min to reach step 43) and tells you about
# exactly one setting. Here the same binary runs the same repair_antennas call on the
# same database, and the shell records each variant's exit code and what it inserted.
# The variant that changes the outcome is then the one to run in the flow.
#
#   ANT_ODB             the database the flow's OpenROAD.DiodeInsertion step would read
#   ANT_VARIANTS        space-separated subset of: base jumper_only diode_only iters1 margin0 margin20
#   OR_BIN              the openroad to drive (default: the one on PATH). Set to run the
#                      same probe under a DIFFERENT OpenROAD build, which is what turns
#                      "pin a build that has the fix" from a claim into a measurement.
set -u
: "${ANT_ODB:?ANT_ODB must be set}"
if [ -n "${OR_BIN:-}" ]; then
    OR=$OR_BIN
else
    OR=$(command -v openroad) || { echo "ANT_DRIVER no openroad on PATH" >&2; exit 1; }
fi
[ -x "$OR" ] || { echo "ANT_DRIVER not executable: $OR" >&2; exit 1; }
O=${ANT_OUTBASE:-/work/ws/probe/out}
ANT_DIODE_CELL=${ANT_DIODE_CELL:-gf180mcu_fd_sc_mcu7t5v0__antenna}
export ANT_DIODE_CELL
if command -v mkdir >/dev/null 2>&1; then
    mkdir -p "$O"
else
    # The pinned image has no coreutils in the nix shell; the pin candidate does.
    python3 -c "import os; os.makedirs('$O', exist_ok=True)"
fi
echo "ANT_DRIVER openroad=$OR ($("$OR" -version 2>&1 | head -2 | tr '\n' ' '))"
echo "ANT_DRIVER odb=$ANT_ODB diode_cell=$ANT_DIODE_CELL variants=${ANT_VARIANTS:-base jumper_only diode_only}"
for V in ${ANT_VARIANTS:-base jumper_only diode_only}; do
    case "$V" in
        base)        ITERS=3; MARGIN=10; JO=0; DO=0 ;;
        jumper_only) ITERS=3; MARGIN=10; JO=1; DO=0 ;;
        diode_only)  ITERS=3; MARGIN=10; JO=0; DO=1 ;;
        iters1)      ITERS=1; MARGIN=10; JO=0; DO=0 ;;
        margin0)     ITERS=3; MARGIN=0;  JO=0; DO=0 ;;
        margin20)    ITERS=3; MARGIN=20; JO=0; DO=0 ;;
        *) echo "ANT_VARIANT_SKIP unknown variant $V"; continue ;;
    esac
    ANT_VARIANT=$V; ANT_ITERS=$ITERS; ANT_MARGIN=$MARGIN
    ANT_JUMPER_ONLY=$JO; ANT_DIODE_ONLY=$DO; ANT_ALLOW_CONG=1
    ANT_OUT=$O/$V; ANT_ODB=$ANT_ODB
    export ANT_VARIANT ANT_ITERS ANT_MARGIN ANT_JUMPER_ONLY ANT_DIODE_ONLY ANT_ALLOW_CONG ANT_OUT ANT_ODB
    echo "ANT_VARIANT_START $V iters=$ITERS margin=$MARGIN jumper_only=$JO diode_only=$DO"
    "$OR" -exit -no_splash /work/ws/probe/antenna_probe.tcl > "$O/$V.log" 2>&1
    rc=$?
    echo "ANT_VARIANT_END $V rc=$rc grt0183_hits=$(grep -c 'GRT-0183' "$O/$V.log") $(grep -o 'Inserted [0-9]* jumpers' "$O/$V.log" | tail -1) $(grep -o 'Inserted [0-9]* diodes' "$O/$V.log" | tail -1) $(grep -o 'Found [0-9]* antenna violations' "$O/$V.log" | tail -1)"
done
echo "ANT_PROBE_DONE"
