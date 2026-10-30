#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# reset_tree_fix.sh -- container side of reset_tree_fix.tcl: tree the reset cone of
# a database with the flow's own CTS settings, and write the result out.
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
openroad -exit -no_splash /work/ws/probe/reset_tree_fix.tcl 2>&1 | tee /work/ws/probe/resetfix/reset_tree_fix.log
