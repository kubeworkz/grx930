#!/usr/bin/env python3
"""Where is the geometry in the die GDS? Per-cell polygon counts, and the std cells' own shapes.

The single-cell LVS probe came back with "comp has 0 polygons" for a child cell. Either that
cell is empty in this GDS (a stream-out that never merged the library GDSs) or the deck read
the wrong cell. This answers it directly, without the deck in the loop.
"""

import klayout.db as db

GDS = "/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"
WATCH = ["gf180mcu_fd_sc_mcu7t5v0__clkinv_1", "gf180mcu_fd_sc_mcu7t5v0__mux2_1",
         "gf180mcu_fd_sc_mcu7t5v0__dffq_1", "VIA_Via1_VV", "VIA_via4_5_3200_6400_4_2_1240_1240"]

ly = db.Layout()
ly.read(GDS)
by_name = {c.name: c for c in ly.each_cell()}


def shapes(cell):
    n = 0
    for li in ly.layer_indexes():
        for sh in cell.shapes(li).each():
            n += 1
    return n


print(f"{ly.cells()} cells")
for name in WATCH:
    c = by_name.get(name)
    print(f"  {name}: shapes={shapes(c) if c else 'ABSENT'} children={c.child_instances() if c else '-'}")

empty = [c.name for c in ly.each_cell() if shapes(c) == 0 and c.child_instances() == 0]
print(f"cells with no shapes and no children: {len(empty)}")
print("  sample:", empty[:12])

top = ly.top_cell()
print(f"top {top.name}: shapes={shapes(top)} children={top.child_instances()}")

# do the standard cells in this die carry geometry at all?
sc = [c for c in ly.each_cell() if c.name.startswith("gf180mcu_fd_sc_")]
sc_empty = [c.name for c in sc if shapes(c) == 0]
print(f"std cell definitions: {len(sc)}, of which empty: {len(sc_empty)}")
if sc and not sc_empty:
    c = sc[0]
    print(f"  example {c.name}: shapes={shapes(c)}")
