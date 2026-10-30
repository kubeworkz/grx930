#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""One real PDK cell, on its own, for a harness sanity run.

The die's cells turned out to be LEF abstracts (pins, wells, boundary -- no comp, no poly), so
before any reconstruction this checks the deck on geometry that certainly has devices: a cell
lifted straight out of the PDK library GDS, compared with its own CDL subcircuit. If this does
not match, the problem is the harness or the switches, not the die.

    python3 build/lvs_chip/mk_pdk_cell_probe.py <cell> [<outname>]
"""

import os
import sys

LIB_GDS = "/work/c930/asic_gf180mcu/build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds"
OUT = "/work/c930/asic_gf180mcu/build/lvs_chip/probe"

CELL = sys.argv[1] if len(sys.argv) > 1 else "gf180mcu_fd_sc_mcu7t5v0__clkinv_1"

import klayout.db as db  # noqa: E402

ly = db.Layout()
ly.read(LIB_GDS)
cell = ly.cell(CELL)
if cell is None:
    raise SystemExit(f"MISS  {CELL} not in {LIB_GDS}")

os.makedirs(OUT, exist_ok=True)
keep = {CELL.lower()}
for index in [c.cell_index() for c in ly.each_cell() if c.name.lower() not in keep]:
    ly.delete_cell(index)
ly.cleanup()
gds = os.path.join(OUT, f"pdk_{CELL}.gds")
ly.write(gds)
print(f"wrote {gds}: tops={[c.name for c in ly.top_cells()]}, cells={ly.cells()}")
