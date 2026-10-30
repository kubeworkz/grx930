#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# antenna_probe_chain.sh -- host side: find out whether any antenna-repair setting
# gets the DIE past the fatal GRT-0183, without paying a 30-minute flow resume per
# setting.
#
# The question: with GRT_ADJUSTMENT 0.1 the die's global routing completes and
# converges, and the resume then dies ~30 min later inside the Antenna Repair stage
# (OpenROAD.RepairAntennas -> OpenROAD.DiodeInsertion -> antenna_repair.tcl ->
# `repair_antennas`), on `[ERROR GRT-0183] Net _167563_: heap underflow during 3D
# maze routing`. That error is fatal only because this build predates OpenROAD's
# recovery change; the router's own no-path is a property of this database. So the
# lever to look for is an argument list whose repair_antennas does not walk into it.
#
# LibreLane exposes exactly four inputs to that call: GRT_ANTENNA_REPAIR_ITERS,
# GRT_ANTENNA_REPAIR_MARGIN, GRT_ANTENNA_REPAIR_JUMPER_ONLY, GRT_ANTENNA_REPAIR_DIODE_ONLY
# (plus GRT_ALLOW_CONGESTION), and ws/probe/antenna_probe.tcl builds the same
# argument list antenna_repair.tcl does. Same binary, same database, same command.
#
# Input database: literally the file the failing step read. die01's repair step names
# its own input in `04-openroad-repairantennas/1-openroad-diodeinsertion/state_in.json`
# and `_env.tcl` (`CURRENT_ODB`): `runs/die01/01-openroad-globalrouting/chip_top.odb`,
# the global-routing output the die02 DRT arm also routed. Its argument list is
# `gf180mcu_fd_sc_mcu7t5v0__antenna -iterations 3 -ratio_margin 10 -allow_congestion`.
#
# HARVEST-ONLY MODE: ANT_HARVEST=1 rewrites the verdict from the logs on disk and
# launches nothing.
#
#   nohup bash build/antenna_probe_chain.sh > /dev/null 2>&1 &
#   tail -f ws/logs/antenna_probe_chain.log
set -u
ROOT=/home/ubuntu/grx930_ol2
WS=$ROOT/ws
B=$ROOT/build
IMG=ghcr.io/wafer-space/gf180mcu-precheck
# ANT_IMAGE/ANT_OR: run the SAME probe under another OpenROAD build, which is the only
# way to answer "does pinning a build with the upstream fix end the abort" without
# rebuilding LibreLane's nix pin. Measured need: this step peaks at 2 GiB RSS on one
# core, so ANT_ALLOW_CONCURRENT=1 (the one-job rule exists for the 8 GiB router, not
# for this) is safe when a repair probe is already running.
IMAGE=${ANT_IMAGE:-$IMG}
OR_BIN=${ANT_OR:-}
# The disk floor is the probe's own worst case (one 232.7 MB ODB per completing variant
# plus logs), so a pin run that must coexist with a large image on this one-filesystem
# box can lower it explicitly rather than silently skipping the gate.
ANT_MIN_GB=${ANT_MIN_GB:-6}
TAG=${ANT_TAG:-ant01}
HOST_OUT=${ANT_HOST_OUT:-$WS/probe/out}
RUNS=$WS/template/librelane/runs/die01
ODB=${ANT_ODB_C:-$RUNS/01-openroad-globalrouting/chip_top.odb}
VARIANTS=${ANT_VARIANTS:-"base jumper_only diode_only margin0"}
# Per-tag chain log: two probes run at once here (the pinned engine and the pin
# candidate), and a shared log makes a variant's result ambiguous afterwards.
LOG=$WS/logs/antenna_probe_chain.$TAG.log
CLOG=$WS/logs/antenna_probe.$TAG.container.log
OUT=$ROOT/drt_fast/verdict/antenna_probe

say() { echo "[$(date -u)] $*" | tee -a "$LOG"; }
ps_running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null; }
. "$B/gate.sh"
mkdir -p "$OUT"

# ---- harvest -------------------------------------------------------------------
harvest() {
    local v rc
    for v in $VARIANTS; do
        rc=$(grep -aE "^ANT_VARIANT_END $v " "$CLOG" "$LOG" 2>/dev/null | grep -oE "rc=[0-9]+" | tail -1)
        printf '%s|%s\n' "$v" "${rc:-?}"
    done
}
if [ "${ANT_HARVEST:-0}" = 1 ]; then
    say "ANT_HARVEST variants='$VARIANTS'"
    harvest | while IFS='|' read -r v rc; do say "HARVEST variant=$v $rc"; done
    say "ANT_PROBE_HARVEST_COMPLETE"
    exit 0
fi

# ---- gate ----------------------------------------------------------------------
# Outputs are one 232.7 MB ODB per completing variant plus logs (worst case ~1.4 GB),
# so the disk floor is the repository-wide 6 GB and the mount is / (this box has one
# filesystem). 9000 MB is the memory floor the repair's own global-routing pass needs
# with margin -- the same figure ws_chain uses for the uncapped flow.
gate 9000 antenna_probe "$ANT_MIN_GB" / || { say "ABORT_$GATE_REASON"; exit 1; }
[ -f "$ODB" ] || { say "ABORT_NO_DB $ODB"; exit 1; }
if [ -n "$(docker ps --format '{{.Names}}')" ] && [ "${ANT_ALLOW_CONCURRENT:-0}" != 1 ]; then
    say "BUSY_OTHER_CONTAINER $(docker ps --format '{{.Names}}' | tr '\n' ' ') -- refusing"
    exit 1
fi
[ "${ANT_ALLOW_CONCURRENT:-0}" = 1 ] && say "CONCURRENT_ALLOWED running alongside: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
[ -f "$ROOT/ws/probe/antenna_probe.tcl" ] || { say "ABORT_NOT_STAGED (stage ws/probe/*)"; exit 1; }

ODB_IN=/work${ODB#$ROOT}
OUT_IN=/work${HOST_OUT#$ROOT}
say "ANT_PROBE_CHAIN_START tag=$TAG image=$IMAGE or_bin='${OR_BIN:-PATH}' variants='$VARIANTS' odb=$ODB $(stat -c %s "$ODB" 2>/dev/null) bytes"
say "FAILING_STEP_INPUT $ODB"
say "FAILING_STEP_ARGS $(grep -ao 'repair_antennas .*' $RUNS/04-openroad-repairantennas/1-openroad-diodeinsertion/openroad-diodeinsertion.log 2>/dev/null | head -1)"
say "FAILING_STEP_PEAK $(grep -ao 'peak[^,]*' $RUNS/04-openroad-repairantennas/1-openroad-diodeinsertion/openroad-diodeinsertion.process_stats.json 2>/dev/null | head -1)"
say "IMAGE_OPENROAD_VERSION $(docker run --rm ${OR_BIN:+-e OR_BIN="$OR_BIN"} "$IMAGE" /bin/sh -c '${OR_BIN:-"$(command -v openroad)"} -version 2>&1 | head -2 | tr "\n" " "' 2>/dev/null | head -1)"

CNAME=ant_probe
[ "$TAG" != ant01 ] && CNAME=ant_probe_$TAG
docker rm -f "$CNAME" >/dev/null 2>&1
docker run -d --name "$CNAME" --user 0:0 -e HOME=/root -v "$ROOT:/work" \
    -e ANT_ODB="$ODB_IN" -e ANT_VARIANTS="$VARIANTS" -e ANT_OUTBASE="$OUT_IN" \
    ${OR_BIN:+-e OR_BIN="$OR_BIN"} \
    $IMAGE /work/ws/probe/antenna_probe.sh >/dev/null
if [ "$(ps_running "$CNAME")" != "true" ]; then
    say "PROBE_NOT_RUNNING $(docker inspect -f 'status={{.State.Status}} rc={{.State.ExitCode}}' "$CNAME" 2>&1 | head -1)"
fi
A0=$(date -u +%s)
say "PROBE_LAUNCHED tag=$TAG container=$CNAME"
while [ "$(ps_running "$CNAME")" = "true" ]; do sleep 30; done
A1=$(date -u +%s)
RC=$(docker inspect -f '{{.State.ExitCode}}' "$CNAME" 2>/dev/null)
docker logs "$CNAME" > "$CLOG" 2>&1
say "PROBE_EXIT rc=$RC wall=$(( (A1-A0)/60 ))m"
grep -aE "^ANT_VARIANT_(START|END)" "$CLOG" | tee -a "$LOG"

# ---- verdict -------------------------------------------------------------------
{
    echo "# Antenna repair: which argument list gets the die past GRT-0183"
    echo
    echo "Written $(date -u '+%Y-%m-%d %H:%M:%S UTC') by \`build/antenna_probe_chain.sh\` (tag \`$TAG\`)."
    echo "OpenROAD: \`$IMAGE\`${OR_BIN:+ \`$OR_BIN\`}. Instrument: that OpenROAD, driving"
    echo "\`ws/probe/antenna_probe.tcl\` — the same \`repair_antennas\` call LibreLane's"
    echo "\`antenna_repair.tcl\` makes, on the same database the repair step reads"
    echo "(\`$(basename "$(dirname "$ODB")")/chip_top.odb\`, $(stat -c %s "$ODB" 2>/dev/null) bytes)."
    echo
    echo "| variant | iters | margin | jumper_only | diode_only | exit | GRT-0183 | jumpers | diodes |"
    echo "|---|---|---|---|---|---|---|---|---|"
    for v in $VARIANTS; do
        L=$HOST_OUT/$v.log
        rc=$(grep -aE "^ANT_VARIANT_END $v " "$CLOG" 2>/dev/null | grep -oE "rc=[0-9]+" | tail -1)
        it=$(grep -aE "^ANT_PROBE_START variant=$v " "$L" 2>/dev/null | grep -oE "iters=[0-9]+" | head -1)
        mg=$(grep -aE "^ANT_PROBE_START variant=$v " "$L" 2>/dev/null | grep -oE "margin=[0-9]+" | head -1)
        jo=$(grep -aE "^ANT_PROBE_START variant=$v " "$L" 2>/dev/null | grep -oE "jumper_only=[01]" | head -1)
        do=$(grep -aE "^ANT_PROBE_START variant=$v " "$L" 2>/dev/null | grep -oE "diode_only=[01]" | head -1)
        h=$(grep -ac 'GRT-0183' "$L" 2>/dev/null)
        j=$(grep -ao 'Inserted [0-9]* jumpers' "$L" 2>/dev/null | tail -1 | grep -oE '[0-9]+')
        d=$(grep -ao 'Inserted [0-9]* diodes' "$L" 2>/dev/null | tail -1 | grep -oE '[0-9]+')
        echo "| \`$v\` | ${it#iters=} | ${mg#margin=} | ${jo#jumper_only=} | ${do#diode_only=} | ${rc#rc=} | $h | ${j:--} | ${d:--} |"
    done
    echo
    echo "Exit 0 with GRT-0183 = 0 is the variant to take into the flow: it is the same"
    echo "binary and the same command, so the flow's own RepairAntennas stage should then"
    echo "complete and the run can reach detailed routing."
    echo
    echo "Logs: \`ws/logs/antenna_probe.$TAG.container.log\`, \`ws/probe/out/<variant>.log\`,"
    echo "and per-variant databases in \`ws/probe/out/<variant>/\`."
} > "$OUT/antenna_probe_$TAG.md"
say "REPORT_WRITTEN $OUT/antenna_probe_$TAG.md"
say "ANT_PROBE_CHAIN_COMPLETE"
exit 0
