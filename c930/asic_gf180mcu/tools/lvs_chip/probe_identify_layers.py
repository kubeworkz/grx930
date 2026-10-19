#!/usr/bin/env python3
"""Name the die GDS's layers from the inside: geometry, not the submission's own list.

The die's stream numbers (1/1, 5/0, 6/0 ... 14/0) are not the PDK's (comp 22/0, metal1 34/0,
via1 35/0 ...), which is why the LVS deck extracted 0 polygons from it. `wafer_space_submission/
verify_layers.py` asserts a mapping, but a mapping asserted in the same package that needs it is
not evidence. This measures instead:

  * per layer number: shape count and total area (metals have big area, cuts have almost none);
  * per via cell (VIA_Via1_VV, ...): which numbers its own geometry uses, and how many instances
    of it the top cell has -- a via cell's contents name the cut layer and the metals it joins;
  * the same counts for the top cell alone, unmerged, so they can be compared with the DEF
    (which names every layer) rather than with a guess.
"""

import os
from collections import Counter, defaultdict

import klayout.db as db

GDS = "/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"

ly = db.Layout()
ly.read(GDS)
top = ly.top_cell()


def layer_key(li):
    info = ly.get_info(li)
    return f"{info.layer}/{info.datatype}"


def cell_stats(cell):
    """{layer: (shapes, texts, area_um2)} for this cell's own geometry only."""
    out = defaultdict(lambda: [0, 0, 0.0])
    for li in ly.layer_indexes():
        for sh in cell.shapes(li).each():
            key = layer_key(li)
            out[key][0] += 1
            if sh.is_text():
                out[key][1] += 1
            elif sh.is_box():
                b = sh.box
                out[key][2] += b.width() * b.height() * ly.dbu * ly.dbu
            else:
                out[key][2] += sh.polygon.area() * ly.dbu * ly.dbu
    return out


print("== top cell's own geometry (routing + fill), per layer number ==")
stats = cell_stats(top)
for key, (n, t, a) in sorted(stats.items(), key=lambda kv: -kv[1][0]):
    print(f"  {key:>6}  shapes={n:>9}  texts={t:>7}  area={a:14.1f} um^2")

print("\n== via cells: their own layers, and how many instances sit in the top cell ==")
inst_count = Counter()
for inst in top.each_inst():
    inst_count[inst.cell.name] += 1
for name in sorted(n for n in inst_count if n.startswith("VIA")):
    cell = ly.cell(name)
    own = cell_stats(cell)
    detail = ", ".join(f"{k}x{n}" for k, (n, _t, _a) in sorted(own.items()))
    print(f"  {name}: instances={inst_count[name]}, own geometry: {detail}")

print("\n== cells referenced by the DEF as via names (if any are absent, the numbers are cuts) ==")
defs = sorted(set(inst_count) - {c.name for c in ly.each_cell()})
print(f"  referenced-but-absent cells: {defs[:5] if defs else 'none'}")
print(f"  GDS path: {os.path.basename(GDS)}, top {top.name}, cells {ly.cells()}")
