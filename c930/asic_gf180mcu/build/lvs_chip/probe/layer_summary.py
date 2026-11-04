#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Per-layer size summary: how much of each metal the die actually draws, and the big shapes.

    python3 layer_summary.py <gds> [layer/datatype ...]
"""

import sys

import klayout.db as db

path = sys.argv[1]
wanted = sys.argv[2:] or ["34/0", "35/0", "36/0", "38/0", "42/0", "40/0", "46/0", "41/0", "81/0"]
ly = db.Layout()
ly.read(path)
top = next(iter(ly.top_cells()))
print(f"{path}: dbu={ly.dbu} top={top.name} bbox={top.bbox()}")
for spec in wanted:
    layer, dt = (int(v) for v in spec.split("/"))
    li = ly.find_layer(layer, dt)
    if li is None:
        print(f"  {spec}: absent")
        continue
    reg = db.Region(top.begin_shapes_rec(li))
    if reg.is_empty():
        print(f"  {spec}: empty")
        continue
    merged = reg.merged()
    sizes = []
    for p in merged.each():
        bb = p.bbox()
        sizes.append((p.area(), bb))
    sizes.sort(key=lambda s: -s[0])
    bb = reg.bbox()
    print(f"  {spec}: shapes={reg.count()} merged={len(sizes)} area={reg.area()} bbox={bb}")
    for area, b in sizes[:5]:
        print(f"     area={area:>14} x {b.left}..{b.right} y {b.bottom}..{b.top} "
              f"w={b.width()} h={b.height()}")
raise SystemExit(0)
