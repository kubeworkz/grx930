#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvs_chip_collect.sh -- wait for the chip LVS run to finish, then judge it into the evidence dir.
#
#   build/lvs_chip_check.sh writes the artifact (the stream-out) and runs the deck on it; on this
#   box that deck run is hours long, so it is normally started detached:
#
#       docker run -d --name lvs_stream -v "$MOUNT:/work" -w /work \
#         ghcr.io/efabless/openlane2:2.3.10 python3 /work/c930/asic_gf180mcu/tools/klayout_lvs.py \
#         --deck /work/c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs \
#         --layout /work/c930/asic_gf180mcu/build/lvs_chip/stream_out.gds \
#         --netlist /work/c930/asic_gf180mcu/build/lvs_chip/grx930_test_chip.cdl \
#         --out /work/c930/asic_gf180mcu/build/lvs_chip/run_chip_stream \
#         --switch metal_level=5LM --switch run_mode=tiling
#
#   This watcher waits for that run, copies the report and the log into
#   `Claude outputs/evidence_lvs_chip/chip_stream/`, and runs the repo's own gate over the report
#   so the exit status is recorded next to the evidence. It judges the *artifact* -- the deck's
#   verdict on stream_out.gds against the CDL -- not the reconstructed die the earlier attempt used.
#
#   A run that is not producing a report is not waited on forever: `--now`, a finished container,
#   or a container that no longer exists all collect what is there. The container name is only
#   consulted when it is given (`--container NAME`), because a run started by lvs_chip_check.sh in
#   the foreground has no container of its own.
#
#   bash build/lvs_chip_collect.sh                 # wait (up to 12 h), then collect
#   bash build/lvs_chip_collect.sh --now           # collect what is there, do not wait
#   bash build/lvs_chip_collect.sh --container lvs_stream   # stop waiting if that container dies
#
# Exit status: the gate's (0 PASS, 1 MISMATCH, 2 CANNOT-RUN), or 3 if there is no report yet.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
WORK=$HERE/lvs_chip
RUN=$WORK/run_chip_stream
EVID=$ROOT/Claude\ outputs/evidence_lvs_chip/chip_stream
LAYOUT=$WORK/stream_out.gds
CDL=$WORK/grx930_test_chip.cdl
DEF=$HERE/grx930_test_chip.def

NOW=0
CONTAINER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --now)          NOW=1; shift ;;
        --run)          RUN=$2; shift 2 ;;
        --run=*)        RUN=${1#*=}; shift ;;
        --container)    CONTAINER=$2; shift 2 ;;
        --container=*)  CONTAINER=${1#*=}; shift ;;
        -h|--help)      sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "lvs_chip_collect: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

# Is the run still capable of producing a report? A dead container is not, and waiting twelve
# hours on it would turn "the run was killed" into "the run is slow".
alive() {
    [ -n "$CONTAINER" ] || return 0
    command -v docker >/dev/null 2>&1 || return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true ]
}

if [ "$NOW" = 0 ]; then
    echo "waiting for $RUN/verdict.json (or the harness to return without one)"
    for _ in $(seq 1 720); do
        [ -f "$RUN/verdict.json" ] && break
        if grep -q 'HARNESS EXIT=' "$RUN/harness.out" 2>/dev/null; then break; fi
        if ! alive; then
            echo "note     container ${CONTAINER} is no longer running: collecting what is there"
            break
        fi
        sleep 60
    done
fi

mkdir -p "$EVID"
if [ ! -f "$RUN/verdict.json" ]; then
    echo "LVS-CHIP: no verdict yet in $RUN"
    [ -f "$RUN/harness.out" ] && cp -f "$RUN/harness.out" "$EVID/harness.out"
    [ -f "$RUN/klayout.log" ] && cp -f "$RUN/klayout.log" "$EVID/klayout.log"
    [ -n "$CONTAINER" ] && docker logs "$CONTAINER" > "$EVID/docker.log" 2>&1
    tail -n 5 "$RUN/klayout.log" 2>/dev/null | cut -c1-200
    exit 3
fi

cp -f "$RUN/verdict.json" "$EVID/verdict.json"
cp -f "$RUN/klayout.log" "$EVID/klayout.log"
# The connectivity answer travels with the deck's verdict: it is the one result that does not
# depend on the netter returning, and a reader of this directory should not have to run anything
# to see it.
if [ -f "$WORK/net_compare.json" ]; then
    cp -f "$WORK/net_compare.json" "$EVID/net_compare.json"
fi
if [ -f "$DEF" ] && [ -f "$CDL" ] && command -v docker >/dev/null 2>&1; then
    mount=$ROOT
    command -v cygpath >/dev/null 2>&1 && mount=$(cygpath -m "$ROOT")
    {   echo "\$ python3 tools/lvs_chip/net_compare.py --def build/grx930_test_chip.def \\"
        echo "      --cdl build/lvs_chip/grx930_test_chip.cdl"
        MSYS_NO_PATHCONV=1 docker run --rm -v "$mount:/work" -w /work \
            "${LVS_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}" python3 \
            /work/c930/asic_gf180mcu/tools/lvs_chip/net_compare.py \
            --def /work/c930/asic_gf180mcu/build/grx930_test_chip.def \
            --cdl /work/c930/asic_gf180mcu/build/lvs_chip/grx930_test_chip.cdl
        echo "exit=$?"
    } > "$EVID/net_compare.txt" 2>&1
fi
[ -f "$RUN/harness.out" ] && cp -f "$RUN/harness.out" "$EVID/harness.out"
# The extracted netlist can be very large; keep it only when it is a sane size.
if [ -f "$RUN/extracted.cir" ] && [ "$(stat -c %s "$RUN/extracted.cir" 2>/dev/null || echo 0)" -lt 50000000 ]; then
    cp -f "$RUN/extracted.cir" "$EVID/extracted.cir"
fi

{
    echo "\$ bash build/lvs_check.sh --report build/lvs_chip/run_chip_stream/verdict.json \\"
    echo "      --layout build/lvs_chip/stream_out.gds --netlist build/lvs_chip/grx930_test_chip.cdl"
    bash "$HERE/lvs_check.sh" --report "$RUN/verdict.json" --layout "$LAYOUT" --netlist "$CDL"
} > "$EVID/gate.txt" 2>&1
RC=$?
echo "gate exit=$RC" >> "$EVID/gate.txt"

echo "collected into $EVID:"
ls -la "$EVID"
cat "$EVID/gate.txt"
[ -f "$EVID/harness.out" ] && tail -n 6 "$EVID/harness.out"
exit $RC
