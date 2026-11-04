# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Every clock metal1 segment against every placed cell's supply tap, as regions.

The unfilled anchored lvsdb has the clock as `CLK,i_clk` with 28,988 terminals; the filled one has
`CLK,VDD,i_clk` with 29,484.  Fill adds exactly one kind of metal1 the design did not have: the
rails and taps of fill/filltie cells (filltie's VDD tap is a full-width 0..1120 x 1.930..3.920
block).  A clock wire inside a row cannot touch a rail band, but it can touch such a tap.  The
earlier version tested only vertical stubs -- 229 of 4,622 segments -- and found nothing; this one
builds the rectangles of all of them and intersects them with all taps as regions.

    python3 clk_vs_taps2.py --def .../grx930_test_chip_filled_metal1.def \
        --lef .../gf180mcu_fd_sc_mcu7t5v0.lef [--width 560]

Exit status 0.
"""

import argparse
import re
from collections import defaultdict

import klayout.db as db

UPRIGHT = ("N", "FN")
COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)")


def parse_lef(path):
    cells, name, pin = {}, None, None
    for line in open(path, errors="replace"):
        s = line.strip()
        m = re.match(r"MACRO (\S+)", s)
        if m:
            name = m.group(1)
            cells[name] = {"size": (0, 0), "supply": []}
            pin = None
            continue
        if name is None:
            continue
        m = re.match(r"SIZE ([\d.]+) BY ([\d.]+)", s)
        if m:
            cells[name]["size"] = (round(float(m.group(1)) * 1000), round(float(m.group(2)) * 1000))
            continue
        if s == "END " + name:
            name, pin = None, None
            continue
        if s == "END":                 # closes a PIN block, not the macro
            pin = None
            continue
        m = re.match(r"PIN (\S+)", s)
        if m:
            pin = m.group(1)
            continue
        if pin in ("VDD", "VSS"):
            m = re.match(r"RECT ([\-\d.]+) ([\-\d.]+) ([\-\d.]+) ([\-\d.]+)", s)
            if m:
                cells[name]["supply"].append((pin,) + tuple(round(float(v) * 1000) for v in m.groups()))
    return cells


def transform(x0, y0, x1, y1, w, h, orient):
    if orient in UPRIGHT:
        if orient == "FN":
            x0, x1 = w - x1, w - x0
        return x0, y0, x1, y1
    nx0, nx1 = (w - x1, w - x0) if orient == "S" else (x0, x1)
    return nx0, h - y1, nx1, h - y0


def clock_rects(path, width):
    """Clock metal1 as rectangles, from the DEF route centre lines."""
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
        half = (int(w) // 2 if w else width // 2)
        x1, y1, x2, y2 = int(x1), int(y1), int(x2), int(y2)
        # DEF units are two per GDS dbu; the taps are built in dbu, so convert here or the two
        # regions never share a coordinate system.
        out.append((min(x1, x2) // 2 - half // 2, min(y1, y2) // 2 - half // 2,
                    max(x1, x2) // 2 + half // 2, max(y1, y2) // 2 + half // 2))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--lef", required=True)
    ap.add_argument("--width", type=int, default=560)
    ap.add_argument("--limit", type=int, default=20)
    args = ap.parse_args()

    cells = parse_lef(args.lef)
    insts = []
    for line in open(args.def_file, errors="replace"):
        m = COMP_RE.match(line.strip())
        if m:
            insts.append((m.group(1), m.group(2), int(m.group(3)) // 2, int(m.group(4)) // 2,
                          m.group(5)))
    print(f"instances={len(insts)} cells={len(cells)}")

    taps = db.Region()
    owner = []
    for inst, cell, x, y, orient in insts:
        w, h = cells[cell]["size"]
        for pin, x0, y0, x1, y1 in cells[cell]["supply"]:
            tx0, ty0, tx1, ty1 = transform(x0, y0, x1, y1, w, h, orient)
            if ty0 < 0 or ty1 > h:          # outside the cell box = the rail band
                continue
            b = db.Box(x + tx0, y + ty0, x + tx1, y + ty1)
            taps.insert(b)
            owner.append((pin, b, inst, cell, orient, x, y))
    print(f"taps={taps.count()}")

    cr = clock_rects(args.def_file, args.width)
    print(f"clock metal1 rectangles={len(cr)}")
    clk = db.Region()
    for r in cr:
        clk.insert(db.Box(*r))
    hits = clk & taps
    print(f"clock metal1 touching a supply tap: {hits.count()} pieces")
    shown = 0
    for p in hits.each():
        bb = p.bbox()
        cx, cy = (bb.left + bb.right) // 2, (bb.bottom + bb.top) // 2
        for pin, b, inst, cell, orient, x, y in owner:
            if b.contains(db.Point(cx, cy)):
                print(f"\n{pin} tap of {inst} {cell} {orient} at ({x},{y})")
                print(f"   tap {b}  clock piece {bb}")
                print(f"   um: tap ({b.left / 1000:.3f},{b.bottom / 1000:.3f}) "
                      f".. ({b.right / 1000:.3f},{b.top / 1000:.3f})")
                shown += 1
                break
        if shown >= args.limit:
            print("\n... more")
            break


if __name__ == "__main__":
    main()
