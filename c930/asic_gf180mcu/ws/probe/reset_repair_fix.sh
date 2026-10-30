#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# reset_repair_fix.sh -- container side of reset_repair_fix.tcl.
#
# Runs the image's own openroad (the pinned build, dcf36133 -- the same commit the
# flow image resolves) against the die's post-antenna-repair database, with the
# design-wide transition/capacitance limits raised so the design repair's target
# set is fanout only: the reset nets. Nothing here writes into a flow run; the
# outputs go to ws/probe/resetfix/ (FIX_OUT_ODB / FIX_OUT_DEF).
set -u
: "${FIX_ODB:?FIX_ODB must be set}"
: "${FIX_OUT_ODB:?FIX_OUT_ODB must be set}"
: "${FIX_OUT_DEF:?FIX_OUT_DEF must be set}"

P=/workspace/gf180mcu/gf180mcuD/libs.ref
export FIX_LIB=$P/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib
export FIX_PAD_LIB=$P/gf180mcu_fd_io/lib/gf180mcu_fd_io__tt_025C_5v00.lib
FIX_MACRO_LIBS=
for m in qrcode_id shuttle_id project_id marker logo; do
    FIX_MACRO_LIBS="$FIX_MACRO_LIBS /work/ws/template/ip/gf180mcu_ws_ip__$m/lib/gf180mcu_ws_ip__$m.lib"
done
export FIX_MACRO_LIBS

cd /work
openroad -version 2>&1 | head -1
openroad -exit -no_splash /work/ws/probe/reset_repair_fix.tcl 2>&1 | tee /work/ws/probe/resetfix/reset_repair_fix.log
