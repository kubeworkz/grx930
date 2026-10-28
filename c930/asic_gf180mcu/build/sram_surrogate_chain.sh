#!/bin/bash
# sram_surrogate_chain.sh -- host side: stage and run the macro-flow surrogate
# (scope §7 step 3) on the flow box, and leave the run tree behind.
#
#   SRAM_TAG=sram01                 fresh run tag (never reuse one: a reused tag
#                                   comes back with its old netlist)
#   SRAM_LIMIT=OpenROAD.GeneratePDN optional: stop after this step. The first
#                                   pass should stop here -- it proves the macro
#                                   declaration, fixed placement and PDN grids
#                                   before the multi-hour run is worth starting
#   SRAM_FROM=OpenROAD.GeneratePDN  optional: resume that tag at this step
#
# What it stages, and why each piece:
#   asic_core/*.sv            the tapeout RTL tree (openlane2_rtl/src) minus the
#                             two unused ROM modules, as run_ws_flow expects
#   src/chip_core.sv          the adapter (chip_top.sv's pad ring is untouched)
#   librelane/macros/         macros_grx930_sram.yaml: the ws_ip block plus the
#                             eight SRAM instances, at fixed locations
#   librelane/pdn/            pdn_cfg_grx930_sram.tcl: the macro grids
#   librelane/                grx930_sram_surrogate.yaml: USE_SRAM_MACRO
#
# The existing routing run's configs stay in place, so a tag built here and a
# tag built by ws_chain.sh differ in exactly the two files above.
set -u
ROOT=${SRAM_ROOT:-/home/ubuntu/grx930_ol2}
WS=$ROOT/ws
TPL=$WS/template
IMG=ghcr.io/wafer-space/gf180mcu-precheck
TAG=${SRAM_TAG:-sram01}
LOG=$WS/logs/sram_surrogate.log
mkdir -p "$WS/logs"
say() { echo "[$(date -u)] $*" | tee -a "$LOG"; }
ps_running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null; }

say "SRAM_CHAIN_START tag=$TAG limit=${SRAM_LIMIT:-none} from=${SRAM_FROM:-none}"
test -d "$TPL/librelane" || { say "ABORT_NOT_STAGED (no $TPL/librelane)"; exit 1; }

# --- staging ---------------------------------------------------------------
mkdir -p "$TPL/asic_core" "$TPL/librelane/macros" "$TPL/librelane/pdn" "$TPL/fill"
rm -f "$TPL"/asic_core/*.sv
for f in "$ROOT"/openlane2_rtl/src/*.sv; do
  case "$(basename "$f")" in
    c930_bootrom.sv|bootrom_wrapper.sv) continue ;;   # unused, and the bootrom's
                                                      # $readmemh has no image
  esac
  cp -f "$f" "$TPL/asic_core/"
done
cp -f "$ROOT"/wafer_space_integration/chip_core_grx930.sv      "$TPL/src/chip_core.sv"
cp -f "$ROOT"/wafer_space_integration/grx930_overrides.yaml    "$TPL/librelane/"
cp -f "$ROOT"/wafer_space_integration/grx930_sram_surrogate.yaml "$TPL/librelane/"
cp -f "$ROOT"/wafer_space_integration/macros_grx930_sram.yaml  "$TPL/librelane/macros/"
cp -f "$ROOT"/wafer_space_integration/pdn_cfg_grx930.tcl       "$TPL/librelane/pdn/"
cp -f "$ROOT"/wafer_space_integration/pdn_cfg_grx930_sram.tcl  "$TPL/librelane/pdn/"
cp -f "$ROOT"/wafer_space_integration/fill/*.rb                "$TPL/fill/" 2>/dev/null || true

# Staged-tree assertions: these are the ways this run fails silently otherwise
# (a missing define builds the FF array, a missing instance list places nothing).
# Matched on the leaf names, not the full hierarchy: LibreLane addresses the
# netlist path (`i_chip_core.u_core.u_sram.u_macro_N`), and a staging check that
# hard-codes the prefix turns a renamed instance into a silent zero here.
n_inst=$(grep -cE 'u_macro_[0-7]:$' "$TPL/librelane/macros/macros_grx930_sram.yaml" || true)
grep -q '^VERILOG_DEFINES:' "$TPL/librelane/grx930_sram_surrogate.yaml" || { say "ABORT_NO_DEFINE"; exit 1; }
grep -q 'USE_SRAM_MACRO' "$TPL/asic_core/grx930_test_chip.sv" || { say "ABORT_RTL_NOT_MACRO_CAPABLE"; exit 1; }
say "SRAM_STAGED core_files=$(ls "$TPL"/asic_core/*.sv | wc -l) macro_instances=$n_inst"
[ "$n_inst" = 8 ] || { say "ABORT_MACRO_INSTANCES (expected 8, got $n_inst)"; exit 1; }

# --- run -------------------------------------------------------------------
# The flow peaks around the routing part's 6.4-7.0 GB; the macros add little.
. "$ROOT/build/gate.sh"
gate 9000 sram_surrogate 10 / || { say "ABORT_$GATE_REASON"; exit 1; }

# The disk guard is started for THIS arm too, not just the routing chains: a
# surrogate extended past GRT writes the same multi-GB ODBs, and the guard is
# what prunes them before the volume fills mid-pass. Started after the launch and
# stopped on every way out, so a killed chain cannot leave a guard pruning the
# next arm's tree.
. "$ROOT/build/disk_guard.sh"
on_exit() {
  local rc=$?
  disk_guard_stop "$TAG" >/dev/null 2>&1 || true
  exit "$rc"
}
trap on_exit EXIT

docker rm -f sram_surrogate >/dev/null 2>&1
docker run -d --name sram_surrogate --user 0:0 -e HOME=/root \
  -v "$ROOT":/work \
  -e "SRAM_TAG=$TAG" -e "SRAM_LIMIT=${SRAM_LIMIT:-}" -e "SRAM_FROM=${SRAM_FROM:-}" \
  "$IMG" /work/ws/sram_surrogate_exec.sh >/dev/null || { say "ABORT_LAUNCH"; exit 1; }
say "SRAM_FLOW_LAUNCHED"
disk_guard_start "$TAG" sram_surrogate

while [ "$(ps_running sram_surrogate)" = "true" ]; do sleep 30; done
disk_guard_stop "$TAG"

docker logs sram_surrogate > "$WS/logs/sram_surrogate.$TAG.log" 2>&1
rc=$(docker inspect -f '{{.State.ExitCode}}' sram_surrogate 2>/dev/null)
say "SRAM_FLOW_EXIT rc=$rc"
RUN=$(ls -1dt "$TPL"/librelane/runs/"$TAG"* 2>/dev/null | head -1)
say "SRAM_RUN_DIR ${RUN:-none}"
if [ -n "${RUN:-}" ]; then
  ls -1 "$RUN" | tail -10 | tee -a "$LOG"
fi
# The macro path's own verdicts, quoted from the flow's logs rather than inferred.
for pat in "No macro instance" "Check Macro Instances" "Generate PDN" "ERROR"; do
  n=$(grep -ac "$pat" "$WS/logs/sram_surrogate.$TAG.log" 2>/dev/null || true)
  say "LOG_MATCH \"$pat\" = ${n:-0}"
done
tail -8 "$WS/logs/sram_surrogate.$TAG.log" | tee -a "$LOG"
df -h / | tail -1 | tee -a "$LOG"
say "SRAM_CHAIN_COMPLETE"
