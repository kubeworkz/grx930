#!/bin/sh
# reset_cts_probe.sh -- container side of reset_cts_probe.tcl.
#
# Runs the image's own openroad (the engine LibreLane resolves in this image, the
# same commit the flow box's CTS used) on a frozen database, so the answer to "can
# CTS tree the reset net" comes from the engine rather than from reading its
# source. Nothing here writes into a flow run: the probe's own outputs go to
# ws/probe/out_cts_probe.*.
#
# PROBE_ODB is the database to read -- a pre-CTS one (the resizer has not
# fragmented the reset yet) is what the CTS step would see.
set -u
: "${PROBE_ODB:?PROBE_ODB must be set}"

export SCRIPTS_DIR=$(python3 -c 'import librelane,os;print(os.path.join(os.path.dirname(librelane.__file__),"scripts"))')
P=/workspace/gf180mcu/gf180mcuD/libs.ref
export PROBE_LIB=$P/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib
export PROBE_PAD_LIB=$P/gf180mcu_fd_io/lib/gf180mcu_fd_io__tt_025C_5v00.lib
PROBE_MACRO_LIBS=
for m in qrcode_id shuttle_id project_id marker logo; do
    PROBE_MACRO_LIBS="$PROBE_MACRO_LIBS /work/ws/template/ip/gf180mcu_ws_ip__$m/lib/gf180mcu_ws_ip__$m.lib"
done
export PROBE_MACRO_LIBS

cd /work
openroad -version 2>&1 | head -1
openroad -exit -no_splash /work/ws/probe/reset_cts_probe.tcl 2>&1 | tee /work/ws/probe/out_cts_probe.log
