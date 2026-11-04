#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Merged metal1 components inside one row-boundary band, and the cells placed there.

The stitch builds its islands from the DEF's placements and the library's rail bands. This checks
that model against the die's own metal1 at a chosen boundary: if the band's components are longer
than the placed runs, something other than abutting cells is joining rails; if they are shorter,
the band is not where the rails are.

    python3 rail_band_components.py <die.gds> <y_boundary_dbu> [<def>]
"""

import re
import sys

import klayout.db as db

gds, yb = sys.argv[1], int(sys.argv[2])
def_file = sys.argv[3] if len(sys.argv) > 3 else ""
HALF = 300

ly = db.Layout()
ly.read(gds)
top = next(iter(ly.top_cells()))
reg = db.Region(top.begin_shapes_rec(ly.layer(34, 0))) & db.Region(
    db.Box(0, yb - HALF, top.bbox().right, yb + HALF))
merged = reg.merged()
print(f"metal1 in band y={yb}+-{HALF}: {merged.count()} components, area={reg.area()}")
for p in merged.each():
    bb = p.bbox()
    print(f"  x {bb.left:8d}..{bb.right:8d} ({(bb.right - bb.left) / 1000.0:8.1f} um) "
          f"y {bb.bottom}..{bb.top} verts={p.num_points}")

if def_file:
    # Which placed cells straddle this boundary (their boxes, from the DEF)?
    comp_re = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)"
                         r"\s+(\w+)")
    cells = []
    for line in open(def_file, errors="replace"):
        m = comp_re.match(line.strip())
        if m:
            x, y = int(m.group(3)) // 2, int(m.group(4)) // 2
            if y == yb or y + 3920 == yb:
                cells.append((x, m.group(5), m.group(1)))
    cells.sort()
    runs = []
    for x, orient, inst in cells:
        if runs and x == runs[-1][1]:
            runs[-1][1] += 3920
            runs[-1][2] += 1
        else:
            runs.append([x, x + 3920, 1, {orient}])
            runs[-1][3] = {orient}
        runs[-1][3].add(orient)
    print(f"placed cells straddling y={yb}: {len(cells)} in {len(runs)} runs")
    for x0, x1, n, orients in runs:
        print(f"  cell run x {x0}..{x1} ({(x1 - x0) / 1000.0:.1f} um) n={n} "
              f"orients={sorted(orients)}")
