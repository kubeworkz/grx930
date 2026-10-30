#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# reset_cts_procs_check.sh -- run the code that ws/tools/librelane_reset_cts_patch.py
# installs, against a database, without a flow.
#
#   CHECK_ODB=<odb> sh reset_cts_procs_check.sh
#
# Why: the patch's Tcl only ever executes inside LibreLane's CTS step, so "the patch
# applied" is not evidence that it does what it says. This applies the patch in this
# container, lifts the patched region out of the image's cts.tcl -- the buffer-list
# helper, the reset-net discovery and declaration, the whole clock_tree_synthesis
# argument list -- and runs it for real: `clock_tree_synthesis {*}$arg_list`, exactly
# the call the step makes, on the database given.
#
#   CHECK_ODB=<pre-CTS odb>   the case the flow runs: the reset is one big net, and
#                             the check should report it treed and the clock treed
#   CHECK_ODB=<fragmented odb> the retrofit case: CTS refuses nets that already have
#                             a clock buffer on them (CTS-0105), and the log says so
#
# Container-local by construction: a fresh container starts from the unmodified image,
# so the patch applied here never leaks into a flow run.
set -u
: "${CHECK_ODB:?CHECK_ODB must be set}"

P=/workspace/gf180mcu/gf180mcuD/libs.ref
export FIX_LIB=$P/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib
export FIX_PAD_LIB=$P/gf180mcu_fd_io/lib/gf180mcu_fd_io__tt_025C_5v00.lib
FIX_MACRO_LIBS=
for m in qrcode_id shuttle_id project_id marker logo; do
    FIX_MACRO_LIBS="$FIX_MACRO_LIBS /work/ws/template/ip/gf180mcu_ws_ip__$m/lib/gf180mcu_ws_ip__$m.lib"
done
export FIX_MACRO_LIBS

PYP=""
command -v python3 >/dev/null 2>&1 && PYP=$(command -v python3)
if [ -z "$PYP" ]; then
    for c in /nix/store/*-python3-3.13.9/bin/python3.13; do
        [ -x "$c" ] && { PYP=$c; break; }
    done
fi
[ -n "$PYP" ] || { echo "PROCS status=no-python"; exit 2; }

export SCRIPTS_DIR=$("$PYP" -c 'import librelane,os;print(os.path.join(os.path.dirname(librelane.__file__),"scripts"))')

"$PYP" /work/ws/tools/librelane_reset_cts_patch.py || exit 2

"$PYP" - <<'PY'
import glob
c = glob.glob("/nix/store/*librelane-*/lib/python3.13/site-packages/librelane/scripts/openroad/cts.tcl")
if not c:
    raise SystemExit("PROCS status=no-cts-tcl")
t = open(c[0]).read()
if "# reset-cts: ws/tools/librelane_reset_cts_patch.py" not in t:
    raise SystemExit("PROCS status=patch-not-in-tcl")
start = t.index("proc get_buflist")
end = t.index("\n", t.index("log_cmd clock_tree_synthesis {*}$arg_list"))
region = t[start:end].replace("log_cmd clock_tree_synthesis {*}$arg_list", "", 1)
head = """source /work/ws/repro_sta/env_cts.tcl
# The flow's own Tcl helpers: cts.tcl builds its argument list with
# append_if_exists_argument / append_if_flag / log_cmd, all defined in this file.
# It reads the step env from _TCL_ENV_IN when sourced (the flow passes it the same
# way), so it is pointed at the env file this check already uses.
set ::env(_TCL_ENV_IN) /work/ws/repro_sta/env_cts.tcl
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
# The three CTS_* values cts.tcl reads unconditionally, at the flow's own defaults
# (grx930_overrides / LibreLane): they are not part of the step env dump env_cts.tcl
# was taken from, and cts.tcl reads them without an exists-guard.
set ::env(CTS_CLK_BUFFERS) {gf180mcu_fd_sc_mcu7t5v0__clkbuf_2 gf180mcu_fd_sc_mcu7t5v0__clkbuf_4 gf180mcu_fd_sc_mcu7t5v0__clkbuf_8}
set ::env(CTS_ROOT_BUFFER) gf180mcu_fd_sc_mcu7t5v0__clkbuf_16
set ::env(CTS_DISTANCE_BETWEEN_BUFFERS) 0
read_lef $::env(TECH_LEF)
foreach l $::env(CELL_LEFS)  { read_lef $l }
foreach l $::env(PAD_LEFS)   { read_lef $l }
foreach l $::env(MACRO_LEFS) { read_lef $l }
read_liberty $::env(FIX_LIB)
read_liberty $::env(FIX_PAD_LIB)
foreach l $::env(FIX_MACRO_LIBS) { read_liberty $l }
read_db $::env(CHECK_ODB)
# cts.tcl's get_buflist uses `$::db`, which the flow's own shell has set by the
# time the script runs; a bare `openroad script.tcl` does not.
set ::db [ord::get_db]
puts "PROCS: instances = [llength [get_cells *]]"
"""
tail = """
puts "PROCS: arg_list = $arg_list"
set ws_before [ws_reset_cone_nets $::env(MAX_FANOUT_CONSTRAINT)]
puts "PROCS: reset nets over limit before = [llength $ws_before]"
foreach n $ws_before {
    puts "PROCS:   before net=$n loads=[ws_net_loads $n]"
}
proc ws_counts {cells} {
    set n 0
    foreach c $cells {
        set n [expr {$n + [llength [get_pins -quiet -of_objects $c]]}]
    }
    return $n
}
puts "PROCS: running clock_tree_synthesis"
clock_tree_synthesis {*}$arg_list
set ws_after [ws_reset_cone_nets $::env(MAX_FANOUT_CONSTRAINT)]
puts "PROCS: reset nets over limit after  = [llength $ws_after]"
foreach n $ws_after {
    puts "PROCS:   after  net=$n loads=[ws_net_loads $n]"
}
puts "PROCS: CTS cells after = [llength [get_cells -quiet clkbuf_*]] clkbuf, [llength [get_cells -quiet clkload*]] clkload"
puts PROCS_DONE
"""
open("/work/ws/probe/reset_cts_procs_test.tcl", "w").write(head + region + tail)
print("PROCS: test file written from", c[0])
PY

cd /work
openroad -version 2>&1 | head -1
openroad -exit -no_splash /work/ws/probe/reset_cts_procs_test.tcl 2>&1 \
    | grep -aE "^PROCS|reset-cts|CTS-00(11|19|28|32|56|83|95|105)|CTS-0001|CTS-0008|ERROR|Error:"
