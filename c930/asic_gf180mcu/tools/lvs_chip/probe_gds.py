# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
import klayout.db as db
p="/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"
ly=db.Layout(); ly.read(p)
print("dbu", ly.dbu, "cells", ly.cells())
t=ly.top_cell(); print("top", t.name, "bbox_um", t.dbbox())
# direct children by name, and instance totals for the whole hierarchy
from collections import Counter
c=Counter()
for inst in t.each_inst():
    c[inst.cell.name]+=1
print("direct children:", len(c))
for n,k in c.most_common(15): print("  ", n, k)
tot=sum(cell.child_instances() for cell in ly.each_cell())
print("total instances in all cells:", tot)
# labels on the top cell: layer/text pairs with coordinates inside the die
texts=0
for layer in ly.layer_indexes():
    li=ly.get_info(layer)
    for s in t.shapes(layer).each():
        if s.is_text():
            texts+=1
            if texts<=25: print("label", li.layer, li.datatype, s.text.string, s.text.trans)
print("text shapes in top cell:", texts)
