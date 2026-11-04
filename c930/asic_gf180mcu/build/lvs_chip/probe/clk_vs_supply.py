# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Clock metal1 against the supply metal each cell actually *draws*, not its LEF pin.

The LEF pin is an abstraction and for some cells it is much smaller than the drawn metal1: filltie
declares a 0.34 x 1.69 tap, but the library GDS draws a full-cell-width 1.120 x 2.29 block
(y 1.930..4.220).  A clock via pad or route stub can therefore sit inside a cell's supply metal
while every LEF-based test passes.  The unfilled die has the clock as `CLK,i_clk` (28,988
terminals) and the filled die as `CLK,VDD,i_clk` (29,484), so the change is in the fill placement --
and this is the test that can see it.

    python3 clk_vs_supply.py --def ...filled_metal1.def --lib .../pdk_fd_sc_mcu7t5v0.gds \
        --layout .../stream_out_filled_metal1.gds [--width 560]

Exit status 0.
"""

import argparse
import re

import klayout.db as db

UPRIGHT = ("N", "FN")
COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)")


def clock_rects(path, width):
    out = []
    net = None
    in_nets = False
    for line in open(path, errors="replace"):
        s = line.strip()
        if s.startswith("NETS "):
            in_nets = True
            continue
        if s == "END NETS":
            break
        if not in_nets:
            continue
        if s.startswith("- "):
            net = s.split()[1]
            continue
        if net != "i_clk" or "Metal1" not in s:
            continue
        t = s[8:] if s.startswith("+ ROUTED ") else (s[4:] if s.startswith("NEW ") else None)
        if t is None:
            continue
        m = re.match(r"Metal1(?: (\d+))?(?: \+ SHAPE \w+)? \( (\d+) (\d+)(?: \d+)? \)"
                     r" \( (\S+) (\S+)(?: \d+)? \)", t)
        if not m:
            continue
        w, x1, y1, x2, y2 = m.groups()
        x2 = x1 if x2 == "*" else x2
        y2 = y1 if y2 == "*" else y2
        # DEF units are two per GDS dbu
        half = (int(w) // 2 if w else width // 2) // 2
        out.append((min(int(x1), int(x2)) // 2 - half, min(int(y1), int(y2)) // 2 - half,
                    max(int(x1), int(x2)) // 2 + half, max(int(y1), int(y2)) // 2 + half))
    return out


def cell_supply(lib):
    """{cell: (w, h, [(net, polygon)])} for the metal1 polygons under the VDD/VSS texts."""
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
        # The cell box is layer 0/0 (the drawn metal bbox includes the well overhang, so it is
        # not the cell height).  The supply metal is whatever metal1 touches the rail band at
        # the box's top or bottom edge; a signal pin never does.
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
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--lib", required=True)
    ap.add_argument("--layout", required=True)
    ap.add_argument("--width", type=int, default=560)
    ap.add_argument("--limit", type=int, default=20)
    ap.add_argument("--vias", action="store_true",
                    help="test via1 pads against the supply metal instead of the clock route")
    args = ap.parse_args()

    lib = db.Layout()
    lib.read(args.lib)
    supply = cell_supply(lib)
    print(f"cell types with drawn supply metal: {len(supply)}")

    region = db.Region()
    owner = []
    insts = 0
    for line in open(args.def_file, errors="replace"):
        m = COMP_RE.match(line.strip())
        if not m:
            continue
        inst, cell, x, y, orient = m.group(1), m.group(2), int(m.group(3)) // 2, \
            int(m.group(4)) // 2, m.group(5)
        if cell not in supply:
            continue
        w, h, shapes = supply[cell]
        insts += 1
        for net, poly in shapes:
            q = transformed(poly, w, h, orient).moved(x, y)
            region.insert(q)
            bb = q.bbox()
            owner.append((net, inst, cell, orient, x, y, bb))

    ly = db.Layout()
    ly.read(args.layout)
    top = ly.top_cell()

    if args.vias:
        # A via1's metal1 enclosure is not in the DEF routing: the pad comes from the via cell in
        # the artifact.  Pad is 260 x 380 for VIA_Via1_VV, cut 260 x 260, so growing the cut by
        # (130, 190) reproduces the drawn pad.
        clk = db.Region(top.begin_shapes_rec(ly.layer(35, 0)))
        clk.size(130, 190)
        print(f"via1 pads (cuts grown 130x190) = {clk.count()}")
    else:
        cr = clock_rects(args.def_file, args.width)
        clk = db.Region()
        for r in cr:
            clk.insert(db.Box(*r))
        print(f"instances={insts} supply polygons={region.count()} clock rects={len(cr)}")
    hits = clk & region
    print(f"clock-side metal overlapping drawn cell supply metal: {hits.count()} pieces")

    shown = 0
    for p in hits.each():
        bb = p.bbox()
        cx, cy = (bb.left + bb.right) // 2, (bb.bottom + bb.top) // 2
        near = [o for o in owner if o[6].contains(db.Point(cx, cy))]
        for net, inst, cell, orient, x, y, _b in near[:1]:
            print(f"\n{net} metal of {inst} {cell} {orient} at ({x},{y})")
            print(f"   clock/supply overlap {bb}  um ({cx / 1000:.3f},{cy / 1000:.3f})")
            shown += 1
        if shown >= args.limit:
            print("\n... more")
            break


if __name__ == "__main__":
    main()
