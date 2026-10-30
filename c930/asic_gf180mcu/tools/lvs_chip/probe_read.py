#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Why did the deck see 0 polygons for a child cell? Compare the two read paths.

The deck calls `source(input, topcell)`. KLayout's read-with-cellname is supposed to keep the
named cell and the cells it needs. This shows, without the deck, what each read path leaves in
the database for the same file and the same cell name.
"""

import klayout.db as db

GDS = "/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"
CELL = "gf180mcu_fd_sc_mcu7t5v0__clkinv_1"


def shapes(cell):
    n = 0
    for li in cell.layout().layer_indexes():
        for _ in cell.shapes(li).each():
            n += 1
    return n


print("== plain read ==")
ly = db.Layout()
ly.read(GDS)
c = ly.cell(CELL)
print(f"cells={ly.cells()} {CELL}: shapes={shapes(c)} children={c.child_instances()}")

print("== read with cellname ==")
ly2 = db.Layout()
ly2.read(GDS, CELL)
print(f"cells={ly2.cells()} top={ly2.top_cell().name} shapes={shapes(ly2.top_cell())}")
print("cell names kept:", [x.name for x in ly2.each_cell()][:5])

print("== cell names, repr, first 5 ==")
print([repr(x.name) for x in list(ly.each_cell())[:5]])
print("exact lookup:", ly.cell(CELL) is not None)
