#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Full layer/shape inventory for one cell, to see what the library GDS actually draws.

    python3 layer_inventory.py <gds> <cell>
"""

import sys

import klayout.db as db

path, name = sys.argv[1], sys.argv[2]
ly = db.Layout()
ly.read(path)
cell = ly.cell(name)
if cell is None:
    print(f"no cell {name}")
    raise SystemExit(2)
print(f"{path} dbu={ly.dbu} cell={cell.name} box={cell.bbox()} "
      f"children={len(list(cell.each_child_cell()))}")
for li in ly.layer_indexes():
    info = ly.get_info(li)
    shapes = list(cell.shapes(li).each())
    if not shapes:
        continue
    boxes = [s for s in shapes if s.is_box()]
    polys = [s for s in shapes if s.is_polygon()]
    texts = [s for s in shapes if s.is_text() and s.text is not None]
    desc = []
    if boxes:
        desc.append(f"box x{min(b.box.left for b in boxes)}..{max(b.box.right for b in boxes)}")
    if polys:
        desc.append(f"poly x{min(p.polygon.bbox().left for p in polys)}.."
                    f"{max(p.polygon.bbox().right for p in polys)}")
    if texts:
        desc.append("texts=" + ",".join(t.text.string for t in texts[:4]))
    print(f"  {info.layer}/{info.datatype}: boxes={len(boxes)} polys={len(polys)} "
          f"texts={len(texts)}  {' '.join(desc)}")
