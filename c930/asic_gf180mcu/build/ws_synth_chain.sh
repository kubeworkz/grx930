#!/bin/bash
# ws_synth_chain.sh -- host side: wait for a DRT-free window, then run the
# wafer.space template flow up to the Yosys synthesis checks, and dump the
# netlist inventory next to the OL2 one for comparison.
#
# Why it waits: the first attempt (tag ws_synth1) was run concurrently with the
# slot-core fast DRT under a 4 GB container cap and was OOM-killed inside ABC
# after 19 min -- correctly, and without touching the DRT (which is the
# experiment we must not disturb). Synthesis of chip_top + pad ring + the
# 370k-cell core needs more than 4 GB, so it runs here in a window where no DRT
# container is alive, with a cap that is still enforced per cgroup, so the
# synthesis can only ever kill itself.
#
#   WS_TAG=ws_synth2 WS_MEMCAP=8g
set -u
ROOT=/home/ubuntu/grx930_ol2
WS=$ROOT/ws
IMG=ghcr.io/wafer-space/gf180mcu-precheck
TAG=${WS_TAG:-ws_synth2}
CAP=${WS_MEMCAP:-8g}
OL2_NL=$ROOT/openlane2_rtl/runs/slotcore_v1/06-yosys-synthesis/grx930_test_chip.nl.v
LOG=$WS/ws_synth_chain.log
say() { echo "[$(date -u)] $*" | tee -a $LOG; }
busy() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^(drt_core|drt_core03|ol2_)'; }
. "$ROOT/build/gate.sh"   # the disk/memory gate, defined once for every chain

mkdir -p $WS/logs
say "SYNTH_CHAIN_START tag=$TAG cap=$CAP"
while busy; do say "WAIT_FOR_WINDOW"; sleep 120; done
say "WINDOW_FREE"
test -d $WS/template/asic_core || { say "ABORT_NOT_STAGED"; exit 1; }

# Gate, shared with the other chains (gate.sh), and the need is derived from the
# cap rather than a second constant, so the two cannot drift apart. This job runs
# under --memory=$CAP: the first attempt was OOM-killed inside ABC at 4 GB, and a
# cap the box cannot back with RAM leaves the run thrashing in swap for hours
# rather than failing fast. It is checked here, after the window wait, so it
# measures the box at launch time and not fifteen minutes earlier. MIN_GB 0 --
# this chain has never had a disk floor, only the memory one that cost it a run.
CAP_MB=$(printf '%s' "$CAP" | awk '/[gG]$/{printf "%.0f", $0*1024; exit} /[mM]$/{printf "%.0f", $0; exit} {print 8192}')
gate "$CAP_MB" ws_synth 0 || { say "ABORT_$GATE_REASON (cap $CAP)"; exit 1; }

docker rm -f ws_synth >/dev/null 2>&1
docker run -d --name ws_synth --user 0:0 -e HOME=/root \
    --memory=$CAP --memory-swap=$CAP \
    -v $ROOT:/work -e "WS_TAG=$TAG" -e WS_LIMIT=Checker.YosysSynthChecks \
    $IMG /work/ws/ws_exec.sh >/dev/null
say "SYNTH_LAUNCHED"
while [ "$(docker inspect -f '{{.State.Running}}' ws_synth 2>/dev/null)" = "true" ]; do sleep 30; done
docker logs ws_synth > $WS/logs/ws_synth.$TAG.log 2>&1
say "SYNTH_DONE exit=$(docker inspect -f '{{.State.ExitCode}}' ws_synth) oom=$(docker inspect -f '{{.State.OOMKilled}}' ws_synth)"
grep -aE "ERROR|%Error|Lint errors|WS_EXIT" $WS/logs/ws_synth.$TAG.log | tail -6 | tee -a $LOG

NL=$(find $WS/template/librelane/runs/$TAG -name '*.nl.v' -printf '%s %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
say "NETLIST ${NL:-none}"
if [ -n "$NL" ]; then
    {
        echo "=== synthesis inventory: $TAG (chip_top = pad ring + ws_ip + grx930 core) ==="
        echo "-- std cells: $(grep -c 'gf180mcu_fd_sc_mcu7t5v0__' "$NL")"
        echo "-- io pads:   $(grep -c 'gf180mcu_fd_io__' "$NL")"
        echo "-- ws_ip:     $(grep -c 'gf180mcu_ws_ip__' "$NL")"
        # NOTE: the flow's `final/nl` netlist is FLATTENED to one `chip_top`
        # module, so grepping it for a submodule name is a false negative (the
        # first version of this check reported "rom: 0" for a design that
        # instantiates it). Ask the synthesis log instead: it records the
        # hierarchy pass's module list.
        SYNL=$(ls $(dirname "$(dirname "$NL")")/06-yosys-synthesis/*.log 2>/dev/null | head -1)
        echo "-- rom instantiated: $(grep -ac 'Used module:.*grx930_test_chip_rom' "$SYNL" 2>/dev/null) (from the hierarchy log)"
        echo "-- used modules:     $(grep -ac 'Used module:' "$SYNL" 2>/dev/null)"
        echo "-- yosys:            $(grep -a -m1 -o 'Yosys 0\.[0-9]*' "$SYNL" 2>/dev/null)"
        echo "-- top-8 std cells:"
        grep -o 'gf180mcu_fd_sc_mcu7t5v0__[a-z0-9_]*' "$NL" | sort | uniq -c | sort -rn | head -8
        echo "-- io pad types:"
        grep -o 'gf180mcu_fd_io__[a-z0-9_]*' "$NL" | sort | uniq -c | sort -rn | head -8
        if [ -f "$OL2_NL" ]; then
            echo
            echo "=== OL2 baseline: slotcore_v1 (core only, pre-ROM/pre-fix RTL) ==="
            echo "-- std cells: $(grep -c 'gf180mcu_fd_sc_mcu7t5v0__' "$OL2_NL")"
            echo "-- io pads:   $(grep -c 'gf180mcu_fd_io__' "$OL2_NL")"
            echo "-- ws_ip:     $(grep -c 'gf180mcu_ws_ip__' "$OL2_NL")"
            echo "-- rom module present: $(grep -c 'grx930_test_chip_rom' "$OL2_NL")"
            echo "-- top-8 std cells:"
            grep -o 'gf180mcu_fd_sc_mcu7t5v0__[a-z0-9_]*' "$OL2_NL" | sort | uniq -c | sort -rn | head -8
        fi
    } > $WS/logs/netlist_compare.$TAG.txt 2>&1
    say "COMPARE_WRITTEN $WS/logs/netlist_compare.$TAG.txt"
fi
say "SYNTH_CHAIN_COMPLETE"
