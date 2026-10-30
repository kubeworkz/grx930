#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# librelane_1023_selftest.sh -- run INSIDE the flow image: apply the #1023
# io.tcl backport twice against the image's installed LibreLane and check both
# the apply and the idempotence, then print the patched region for eyeballing.
#
#   docker run --rm -v /home/ubuntu/grx930_ol2:/work --entrypoint /bin/sh \
#       ghcr.io/wafer-space/gf180mcu-precheck -c \
#       'sh /work/ws/tools/librelane_1023_selftest.sh'
#
# What it proves: the pre-image strings this image actually has match the patch
# (run 1 = applied, edits and self-checks counted), a second invocation is a
# no-op (run 2 = already-patched) -- which matters because
# ws/die_predrt_exec.sh may be re-run in any container, and a patch that
# doubled its own edits would corrupt io.tcl silently. It does NOT prove the
# end-to-end flow: that needs the pin arm's own resume (PREDRT_OR +
# PREDRT_PATCH_LLN=1023 through build/die_drt_chain.sh).
set -u
F=/work/ws/tools/librelane_1023_io_patch.py
[ -f "$F" ] || { echo "SELFTEST: no $F -- stage ws/tools to /work/ws/tools first"; exit 2; }
PYP=$(command -v python3 2>/dev/null || true)
if [ -z "${PYP:-}" ]; then
    for c in /nix/store/*-python3-3.13.9/bin/python3.13; do
        [ -x "$c" ] && { PYP=$c; break; }
    done
fi
echo "SELFTEST python=$PYP"
echo "--- run 1 (expect status=applied) ---"
"$PYP" "$F"
R1=$?
echo "--- run 2 (expect status=already-patched) ---"
"$PYP" "$F"
R2=$?
echo "--- patched region ---"
for f in /nix/store/*librelane*/lib/python*/site-packages/librelane/scripts/openroad/common/io.tcl; do
    grep -n "proc scene_name\|sta::is_object\|sta::get_property \$scene name\|scene_name \$scene\|sta::find_scene\|sta::set_scene \$corner_name" "$f"
done
RC=0
[ "$R1" = 0 ] || RC=1
[ "$R2" = 0 ] || RC=1
echo "SELFTEST rc=$RC"
exit $RC
