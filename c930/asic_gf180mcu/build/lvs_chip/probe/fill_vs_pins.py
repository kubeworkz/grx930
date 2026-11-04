# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Fill-cell supply metal against every metal1 pin drawn in the row interior.

The fill adds no signal geometry, so a fill cell can only short a signal by having its own supply
metal (rail, or filltie's full-width 1.120 x 2.29 block) land on a pin.  Rails overlap other rails
by design, so this test excludes everything inside a 0.6 um rail band and keeps only metal1 that
lies strictly inside a row: those shapes are pins, and no supply metal belongs on them.

    python3 fill_vs_pins.py --lib .../pdk_fd_sc_mcu7t5v0.gds --def ...filled_metal1.def \
        --layout .../stream_out_filled_metal1.gds [--limit 20]

Exit status 0.
"""

import argparse
import re
from bisect import bisect_left

import klayout.db as db

COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)")
ROW_RE = re.compile(r"^ROW\s+(\S+)\s+\S+\s+(\d+)\s+(\d+)\s+\w+")
FILL = "FILL_ROW_"
UPRIGHT = ("N", "FN")


def library_supply(lib):
    """{cell: (w, h, [(net, polygon)])} -- the metal1 that touches a rail band."""
    m1 = lib.layer(34, 0)
    text = lib.layer(34, 10)
    out = {}
    for cell in lib.each_cell():
        name = cell.name
        if not name.startswith("gf180mcu_fd_sc_mcu7t5v0__"):
            continue
        pos = {}
        for s in cell.shapes(text).each():
            if s.is_text() and s.text and s.text.string in ("VDD", "VSS"):
                pos[s.text.string] = s.text.trans.disp
        if len(pos) != 2:
            continue
        box = cell.bbox(lib.layer(0, 0))
        if box is None or box.empty():
            continue
        cw, ch = box.width(), box.height()
        vdd_top = pos["VDD"].y > pos["VSS"].y
        shapes = []
        for poly in db.Region(cell.begin_shapes_rec(m1)).each():
            bb = poly.bbox()
            if bb.bottom >= ch / 2 and bb.top >= ch - 300:
                shapes.append(("VDD" if vdd_top else "VSS", poly))
            elif bb.top <= ch / 2 and bb.bottom <= 300:
                shapes.append(("VSS" if vdd_top else "VDD", poly))
        if shapes:
            out[name] = (cw, ch, shapes)
    return out


def transformed(poly, w, h, orient):
    pts = [(p.x, p.y) for p in poly.each_point_hull()]
    if orient in ("FS", "S"):
        pts = [(x, h - y) for x, y in pts]
    if orient in ("FN", "S"):
        pts = [(w - x, y) for x, y in pts]
    return db.Polygon([db.Point(x, y) for x, y in pts])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True)
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--layout", required=True)
    ap.add_argument("--limit", type=int, default=20)
    args = ap.parse_args()

    lib = db.Layout()
    lib.read(args.lib)
    supply = library_supply(lib)
    print(f"cell types with supply metal: {len(supply)}")

    fill = db.Region()
    fill_owner = []
    rows = []
    for line in open(args.def_file, errors="replace"):
        m = ROW_RE.match(line.strip())
        if m:
            rows.append(int(m.group(3)) // 2)
            continue
        m = COMP_RE.match(line.strip())
        if not m or not m.group(1).startswith(FILL):
            continue
        inst, cell, x, y, orient = m.group(1), m.group(2), int(m.group(3)) // 2, \
            int(m.group(4)) // 2, m.group(5)
        if cell not in supply:
            continue
        w, h, shapes = supply[cell]
        for net, poly in shapes:
            q = transformed(poly, w, h, orient).moved(x, y)
            fill.insert(q)
            fill_owner.append((net, inst, cell, orient, x, y, q.bbox()))
    rows.sort()
    print(f"fill supply polygons: {fill.count()}  row lines: {len(rows)}")

    ly = db.Layout()
    ly.read(args.layout)
    top = ly.top_cell()
    m1 = db.Region(top.begin_shapes_rec(ly.layer(34, 0)))
    pins = db.Region()
    kept = skipped = 0
    for p in m1.each():
        bb = p.bbox()
        i = bisect_left(rows, bb.bottom - 300)
        in_band = False
        for j in (i - 1, i, i + 1):
            if 0 <= j < len(rows):
                y = rows[j]
                if bb.bottom <= y + 300 and bb.top >= y - 300:
                    in_band = True
                    break
        if in_band:
            skipped += 1
        else:
            pins.insert(p)
            kept += 1
    print(f"metal1 shapes: {m1.count()}  in a rail band: {skipped}  row-interior (pins): {kept}")

    hits = fill & pins
    print(f"fill supply metal over a row-interior pin: {hits.count()} pieces")
    for p in hits.each():
        bb = p.bbox()
        cx, cy = (bb.left + bb.right) // 2, (bb.bottom + bb.top) // 2
        own = [o for o in fill_owner if o[0] is not None and o[6].contains(db.Point(cx, cy))]
        for net, inst, cell, orient, x, y, _b in own[:1]:
            print(f"\n{net} metal of {inst} {cell} {orient} at ({x},{y})")
            print(f"   over pin metal {bb}  um ({cx / 1000:.3f},{cy / 1000:.3f})")
        if bb.height() > 5000:
            print(f"   (large piece {bb})")


if __name__ == "__main__":
    main()
