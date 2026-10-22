#!/usr/bin/env python3
"""Rebuild the September die into a stream LVS can extract: real cells, PDK layer numbers.

What the die is
---------------
grx930_test_chip_final.gds carries no device geometry. Its standard cells are LEF abstracts --
pin rectangles, wells and a boundary -- and its layer numbers are a LEF/DEF index scheme
(Metal1=5/0, Via1=6/0, Metal2=7/0, ... Metal5=13/0; Pwell=1, Nwell=2, cell boundary=14, die
boundary=15; datatype 0 = routed shapes, 1 = labels, 2/3 = LEF pin/obstruction shapes). The LVS
deck, which reads the PDK's numbers (comp 22/0, poly2 30/0, contact 33/0, metal1 34/0 ...), finds
nothing in it: "Total no. of polygons in the design is 0".

What this does
--------------
Keeps the die's routing and its cell placements, and rebuilds the file the flow should have
written:

  * the 34 standard cells come from the PDK library GDS -- real transistors, PDK numbering;
  * the die's routed geometry is remapped onto PDK numbers (5/0->34/0, 6/0->35/0, 7/0->36/0,
    8/0->38/0, 9/0->42/0, 10/0->40/0, 11/0->46/0, 12/0->41/0, 13/0->81/0, labels -> *10);
  * the six DEF via cells are rebuilt with the same remap, and instanced as before;
  * the LEF abstracts, the well shapes and the boundary markers are dropped -- the real cells
    carry wells and pins themselves.

The result is only as good as the two inputs, and it is *not* the submitted artifact: it is the
artifact with its cells restored to the layouts the PDK ships. LVS on it answers "does the die's
routing agree with the routed netlist", which is the question that can be answered today.
"""

import os
from collections import Counter

import klayout.db as db

LIB = "/work/c930/asic_gf180mcu/build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds"
DIE = "/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"
OUT = "/work/c930/asic_gf180mcu/build/lvs_chip/reconstructed.gds"

# die (layer, datatype) -> PDK (layer, datatype)
REMAP = {
    (5, 0): (34, 0),   # Metal1
    (5, 1): (34, 10),  # Metal1 label
    (6, 0): (35, 0),   # Via1
    (7, 0): (36, 0),   # Metal2
    (7, 1): (36, 10),
    (8, 0): (38, 0),   # Via2
    (9, 0): (42, 0),   # Metal3
    (9, 1): (42, 10),
    (10, 0): (40, 0),  # Via3
    (11, 0): (46, 0),  # Metal4
    (11, 1): (46, 10),
    (12, 0): (41, 0),  # Via4
    (13, 0): (81, 0),  # Metal5
    (13, 1): (81, 10),
}
# dropped on purpose: (1,*) pwell abstract, (2,*) nwell abstract, (14,0) cell boundary,
# (15,0) die boundary, (3,0) seal ring (present only in the sealed file).


def copy_shapes(src_layout, src_cell, dst_layout, dst_cell, remap, dropped):
    moved = 0
    for li in src_layout.layer_indexes():
        info = src_layout.get_info(li)
        key = (info.layer, info.datatype)
        target = remap.get(key)
        if target is None:
            dropped[key] = dropped.get(key, 0) + 1
            continue
        dst_layer = dst_layout.layer(*target)
        shapes = dst_cell.shapes(dst_layer)
        for sh in src_cell.shapes(li).each():
            if sh.is_text():
                shapes.insert(db.Text(sh.text.string, sh.text.trans))
            elif sh.is_box():
                shapes.insert(sh.box)
            elif sh.is_polygon():
                shapes.insert(sh.polygon)
            elif sh.is_path():
                shapes.insert(sh.path)
            moved += 1
    return moved


def main():
    out = db.Layout()
    out.read(LIB)  # the real cells, already in PDK numbering
    lib_cells = {c.name: c for c in out.each_cell()}
    print(f"library: {len(lib_cells)} cells")

    die = db.Layout()
    die.read(DIE)
    die_top = die.top_cell()

    top = out.create_cell(die_top.name)
    dropped = Counter()
    moved = copy_shapes(die, die_top, out, top, REMAP, dropped)
    print(f"top cell {top.name}: {moved} routed shapes moved, dropped {dict(dropped)}")

    via_cells = {}
    instances = Counter()
    for inst in die_top.each_inst():
        name = inst.cell.name
        target = lib_cells.get(name)
        if target is None:
            # a DEF via cell: rebuild it here with the same remap
            target = via_cells.get(name)
            if target is None:
                target = out.create_cell(name)
                copy_shapes(die, inst.cell, out, target, REMAP, dropped)
                via_cells[name] = target
        top.insert(db.CellInstArray(target.cell_index(), inst.dcplx_trans))
        instances[name] += 1

    std = sum(n for name, n in instances.items() if name.startswith("gf180mcu_fd_sc"))
    vias = sum(n for name, n in instances.items() if name.startswith("VIA"))
    other = {name: n for name, n in instances.items()
             if not name.startswith(("gf180mcu_fd_sc", "VIA"))}
    print(f"instances: {std} standard cells, {vias} vias, other={other}")

    # what the deck will see: device layers must be present now
    counts = Counter()
    for li in out.layer_indexes():
        info = out.get_info(li)
        n = 0
        it = top.begin_shapes_rec(li)
        while not it.at_end():
            n += 1
            it.next()
        counts[(info.layer, info.datatype)] = n
    for key in [(22, 0), (30, 0), (33, 0), (34, 0), (34, 10), (21, 0), (204, 0), (35, 0),
                (36, 0), (38, 0), (42, 0), (40, 0), (46, 0), (41, 0), (81, 0)]:
        print(f"  {key[0]:>3}/{key[1]:<2} shapes={counts.get(key, 0)}")

    out.write(OUT)
    print(f"wrote {OUT} ({os.path.getsize(OUT)} B), cells={out.cells()}")


if __name__ == "__main__":
    main()
