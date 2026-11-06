#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Insert the welltap step into the OpenROAD flow, between placement and routing.

The fill pass can only tap a well where two sites are free and the filltie's Metal1 stubs are
clear. On the 2026-11-05 die that left 21 nwell runs untied: ten packed solid with cells, eight
with Metal1 across every candidate window, one both. DF.13_LV wants a tap within 20 um of the
p-diffusion in an nwell, so the taps have to be placed before global_route draws over them.

    python3 add_tapcell.py FLOW.tcl [FLOW.tcl ...]

Idempotent: a file that already contains `tapcell -distance` is left alone.
"""

import sys

BLOCK = """improve_placement

# 6b. Well taps, before routing. The fill pass can only tap a well where two sites are free and
# the filltie Metal1 stubs are clear; on the 2026-11-05 die that left 21 nwell runs untied (10
# packed solid with cells, 8 with Metal1 across every candidate window). DF.13_LV wants a tap
# within 20 um of the p-diffusion in an nwell, so the taps go in here, before global_route
# draws over them. TAP_PROBE=1 stops after placement and writes build/place_tap_probe.def.
puts "STAGE tapcell start"
tapcell -distance 20 -tapcell_master gf180mcu_fd_sc_mcu7t5v0__filltie -disallow_one_site_gaps
detailed_placement
puts "STAGE tapcell done"
if {[info exists ::env(TAP_PROBE)]} {
    write_def ${BUILD_DIR}/place_tap_probe.def
    puts "TAP_PROBE_DONE"
    exit
}
puts "STAGE placement done\""""


def patch(path):
    src = open(path).read()
    if "tapcell -distance" in src:
        print(f"{path}: already patched")
        return 0
    old = "improve_placement\nputs \"STAGE placement done\""
    if old not in src:
        print(f"{path}: REFUSED, placement block not found")
        return 2
    open(path + ".bak", "w").write(src)
    open(path, "w").write(src.replace(old, BLOCK, 1))
    print(f"{path}: patched (backup {path}.bak)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    raise SystemExit(max(patch(p) for p in sys.argv[1:]))
