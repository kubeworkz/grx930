#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""drc_lib_exposure.py -- how much of a rule's exposure lives inside the shipped cell libraries.

WHY THIS EXISTS
  The run2 artifact reports CO.1 (contact size) and M1.2a (metal1 spacing) as its two biggest
  non-off-grid failures. Both rules are evaluated on geometry that comes mostly from cells
  nobody in this project drew: the pad ring (gf180mcu_fd_io), the SRAM macros, the standard
  cells. Before treating those violations as this design's bugs, measure what the libraries
  themselves carry.

  CO.1 is a good first target because the deck implements it as an exact-edge test:

      co1_l1 = contact.edges.without_length(0.22.um)     # rule_decks/contact.rb

  With the deck's default run_mode ('deep'), generic_layers.rb does NOT merge layers
  (`merge = (ctx.options.run_mode != 'deep')`), so this runs on contacts as drawn: every
  drawn contact edge that is not exactly 0.22 um is one reported item.

WHAT IT DOES
  For a layer (default 33/0 = contact) in a GDS cell library, per cell:
    * how many drawn polygons violate the exact-edge test,
    * how those split into "shorter than 0.22 um" (a real min-size miss)
      and "longer than 0.22 um" (a merged/strip contact, or a genuine max-size miss).
  Cell-local, so it is a lower bound on a die that instances the cells repeatedly.

USAGE
  python3 tools/drc_lib_exposure.py --layer 33 --size-um 0.22 LIB.gds [LIB2.gds ...]
  python3 tools/drc_lib_exposure.py --layer 33 --size-um 0.22 --cells 8 FILE.gds

EXIT STATUS
  0  measured at least one file; 2  no file could be read
"""

import argparse
import os
import sys

try:
    import klayout.db as kdb
except ImportError:  # pragma: no cover - environment, not logic
    sys.stderr.write("klayout.db is required (pip install klayout)\n")
    sys.exit(2)


def polygon_edges(poly):
    """Yield (x1, y1, x2, y2) for each edge of a polygon, in dbu."""
    pts = list(poly.each_point_hull())
    n = len(pts)
    for i in range(n):
        a = pts[i]
        b = pts[(i + 1) % n]
        yield a.x, a.y, b.x, b.y


def edge_length_dbu(x1, y1, x2, y2):
    """KLayout's Edge#length is the euclidean distance; dbu units, so 0.22 um = 220."""
    dx = abs(x2 - x1)
    dy = abs(y2 - y1)
    # exact for the axis-aligned edges contacts are made of; the sqrt is the general case
    return dx if dy == 0 else (dy if dx == 0 else int(round((dx * dx + dy * dy) ** 0.5)))


def scan(path, layer, datatype, size_dbu, top_cells):
    ly = kdb.Layout()
    ly.read(path)
    if ly.dbu and abs(ly.dbu - 0.001) > 1e-9:
        sys.stderr.write("%s: dbu is %.6g um, not 0.001 -- sizes below are in dbu regardless\n"
                         % (os.path.basename(path), ly.dbu))
    li = ly.layer(layer, datatype)
    tot_polys = tot_bad = tot_short = tot_long = 0
    per_cell = []
    for cell in ly.each_cell():
        shapes = cell.shapes(li)
        if shapes.is_empty():
            continue
        polys = 0
        bad = short = long_ = 0
        # Region from the cell's shapes does not merge, which matches the deck's default
        # run_mode ('deep'): the rule sees contacts as drawn, not as a merged layer.
        for poly in kdb.Region(shapes).each():
            polys += 1
            bad_here = False
            for x1, y1, x2, y2 in polygon_edges(poly):
                ln = edge_length_dbu(x1, y1, x2, y2)
                if ln != size_dbu:
                    bad_here = True
                    if ln < size_dbu:
                        short += 1
                    else:
                        long_ += 1
            if bad_here:
                bad += 1
        if not polys:
            continue
        tot_polys += polys
        tot_bad += bad
        tot_short += short
        tot_long += long_
        if bad:
            per_cell.append((bad, short, long_, cell.name, polys))

    per_cell.sort(reverse=True)
    print("== %s  layer %d/%d  target edge %.3f um (%d dbu)  cells with violations: %d"
          % (os.path.basename(path), layer, datatype, size_dbu / 1000.0, size_dbu, len(per_cell)))
    print("   drawn polygons %d   violating >=1 edge %d (%.1f%%)"
          % (tot_polys, tot_bad, 100.0 * tot_bad / max(1, tot_polys)))
    print("   offending edges: shorter than target %d, longer than target %d"
          % (tot_short, tot_long))
    for bad, short, long_, name, polys in per_cell[:top_cells]:
        print("     %-46s %5d/%5d polys, %5d short, %5d long"
              % (name[:46], bad, polys, short, long_))
    print()
    return tot_polys, tot_bad


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gds", nargs="+")
    ap.add_argument("--layer", type=int, default=33, help="GDS layer (33 = contact)")
    ap.add_argument("--datatype", type=int, default=0)
    ap.add_argument("--size-um", type=float, default=0.22, help="the rule's exact edge, in um")
    ap.add_argument("--cells", type=int, default=6, help="per-cell rows to print")
    args = ap.parse_args()

    size_dbu = int(round(args.size_um * 1000))
    measured = 0
    for path in args.gds:
        if not os.path.isfile(path):
            sys.stderr.write("not a file: %s\n" % path)
            continue
        scan(path, args.layer, args.datatype, size_dbu, args.cells)
        measured += 1
    return 0 if measured else 2


if __name__ == "__main__":
    sys.exit(main())
