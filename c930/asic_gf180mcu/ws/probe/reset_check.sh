#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# reset_check.sh -- container side of reset_check.tcl.
#
#   CHECK_ODB=<odb> sh reset_check.sh
#
# Read-only measurement of the reset cone and the design's fanout tail, so the
# 2,132-load buffer and its removal are both read off a database rather than
# inferred from a timing report's worst path.
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

cd /work
openroad -exit -no_splash /work/ws/probe/reset_check.tcl 2>&1
