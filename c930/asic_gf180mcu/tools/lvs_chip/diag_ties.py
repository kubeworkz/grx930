#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Why 18 of the 21 well anchors could not take a filltie.

The patched fill_def.py refuses rather than write a partial fix, so the first run placed 3 and
refused 18. This prints, per anchor, what the site actually offers: how many row sites the well
segment spans, how many are free of cells, how many free two-site windows clear the rails, and how
many of those also clear the filltie's whole box (its two metal1 stubs are the difference).

    python3 tools/lvs_chip/diag_ties.py --def ... --lef ... --anchors ...
"""

import argparse
import sys

sys.path.insert(0, "/work/c930/asic_gf180mcu/tools/lvs_chip")
import fill_def as F  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--lef", required=True)
    ap.add_argument("--anchors", required=True)
    a = ap.parse_args()

    units, rows, comps, metal1, _shapes = F.parse_def(a.def_file)
    sizes = F.lef_sizes(a.lef)
    routes = F.Routes(metal1)
    step = rows[0][5]
    cell_h = int(round(sizes[comps[0][1]][1] * units))
    row_by_y = {r[2]: r for r in rows}
    occup = {}
    for _i, cell, x, y, _o in comps:
        w = int(round(sizes[cell][0] * units))
        occup.setdefault(y, []).append((x, x + w))
    for y in occup:
        occup[y].sort()

    def rails_clear(x, w):
        return not (routes.hits(x, y - F.RAIL_HALF, x + w, y + F.RAIL_HALF) or
                    routes.hits(x, y + cell_h - F.RAIL_HALF, x + w, y + cell_h + F.RAIL_HALF))

    print(f"site {step} dbu, cell height {cell_h} dbu, tie {F.TIE_SITES} sites")
    for line in open(a.anchors):
        s = line.split()
        if len(s) != 3:
            continue
        y, lo, hi = (int(v) for v in s)
        row = row_by_y.get(y)
        if row is None:
            print(f"y={y}: no ROW")
            continue
        x0, sites = row[1], row[4]
        n = (hi - lo) // step
        occ = occup.get(y, [])
        free = [not any(o0 <= lo + i * step < o1 for o0, o1 in occ) for i in range(n)]
        two = [free[i] and free[i + 1] for i in range(max(0, n - 1))]
        rail = [two[i] and rails_clear(lo + i * step, F.TIE_SITES * step) for i in range(len(two))]
        box = [rail[i] and not routes.hits(lo + i * step, y, lo + (i + 2) * step, y + cell_h)
               for i in range(len(rail))]
        cellw = sum(1 for i in range(n) if not free[i])
        print(f"y={y} row {y // 7840} x {lo}..{hi} sites {n} cell-covered {cellw} "
              f"free2={sum(two)} rails_ok={sum(rail)} box_ok={sum(box)}")
        if not any(box) and any(rail):
            i = rail.index(True)
            xs = lo + i * step
            hits = [(bx0, by0, bx1, by1) for bx0, by0, bx1, by1 in metal1
                    if bx0 < xs + 2 * step and bx1 > xs and by0 < y + cell_h and by1 > y]
            print(f"    best rails_ok window x={xs}: {len(hits)} metal1 box(es) in the tie box")
            for h in hits[:4]:
                print(f"      {h}")


if __name__ == "__main__":
    main()
