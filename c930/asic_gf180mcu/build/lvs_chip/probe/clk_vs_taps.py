# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Test the clock's metal1 wiring against every placed cell's VDD/VSS tap, not just its rail band.

`clk_short_def.py` rebuilt the rail bands (0.6 um, centred on a row line) and found the routed
clock clear of all of them.  But a cell's supply pin is not only the band: the LEF gives each one a
*tap* that runs up to 1.2 um into the row (clkinv_1 VDD: 0.245..0.475 x 2.480..3.620; filltie:
0.000..1.120 x 1.930..3.920).  A clock pin-access stub that lands next to a cell boundary can
therefore touch a neighbour's tap without ever entering the band, which is exactly the shape of a
one-island defect.  This tests every clock metal1 segment against the transformed tap rectangles of
all 147,905 placed cells.

    python3 clk_vs_taps.py --def .../grx930_test_chip_filled_metal1.def \
        --lef .../gf180mcu_fd_sc_mcu7t5v0.lef [--width 280]

Exit status 0.
"""

import argparse
import re
from bisect import bisect_left
from collections import defaultdict

ROW_H = 7840
ROW_HALF = 600
COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)")
UPRIGHT = ("N", "FN")


def parse_lef(path):
    """{cell: {'size': (w,h), 'supply': [(pin, x0,y0,x1,y1)]}} in DEF units."""
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
            cells[name]["size"] = (round(float(m.group(1)) * 2000), round(float(m.group(2)) * 2000))
            continue
        if s == "END " + name:
            name, pin = None, None
            continue
        m = re.match(r"PIN (\S+)", s)
        if m:
            pin = m.group(1)
            continue
        if pin and pin in ("VDD", "VSS"):
            m = re.match(r"RECT ([\-\d.]+) ([\-\d.]+) ([\-\d.]+) ([\-\d.]+)", s)
            if m:
                x0, y0, x1, y1 = (round(float(v) * 2000) for v in m.groups())
                cells[name]["supply"].append((pin, x0, y0, x1, y1))
    return cells


def parse_def(path):
    comps, clk = [], []
    net = None
    in_nets = False
    for line in open(path, errors="replace"):
        s = line.strip()
        m = COMP_RE.match(s)
        if m:
            comps.append((m.group(1), m.group(2), int(m.group(3)), int(m.group(4)), m.group(5)))
            continue
        if s.startswith("NETS "):
            in_nets = True
            continue
        if s == "END NETS":
            in_nets = False
            continue
        if not in_nets:
            continue
        if s.startswith("- i_clk "):
            net = "i_clk"
            continue
        if s.startswith("- "):
            net = None
            continue
        if net != "i_clk":
            continue
        t = s[8:] if s.startswith("+ ROUTED ") else (s[4:] if s.startswith("NEW ") else None)
        if t is None:
            continue
        m = re.match(r"(Metal[1-5])(?: (\d+))?(?: \+ SHAPE \w+)? \( (\d+) (\d+)(?: \d+)? \)"
                     r" \( (\S+) (\S+)(?: \d+)? \)", t)
        if not m or m.group(1) != "Metal1":
            continue
        layer, w, x1, y1, x2, y2 = m.groups()
        x2 = x1 if x2 == "*" else x2
        y2 = y1 if y2 == "*" else y2
        clk.append((int(w) if w else 0, int(x1), int(y1), int(x2), int(y2)))
    return comps, clk


def transform(x0, y0, x1, y1, cell_w, cell_h, orient):
    """Library rect -> DEF space for the four on-row orientations."""
    if orient in UPRIGHT:                      # N, FN: only x may mirror
        if orient == "FN":
            x0, x1 = cell_w - x1, cell_w - x0
        return x0, y0, x1, y1
    # FS, S: y flips; FS also keeps x, S mirrors x
    nx0, nx1 = (cell_w - x1, cell_w - x0) if orient == "S" else (x0, x1)
    return nx0, cell_h - y1, nx1, cell_h - y0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--lef", required=True)
    ap.add_argument("--width", type=int, default=280, help="Metal1 wire width in DEF units")
    ap.add_argument("--limit", type=int, default=20)
    args = ap.parse_args()

    cells = parse_lef(args.lef)
    comps, clk = parse_def(args.def_file)
    print(f"cells={len(cells)} components={len(comps)} clock metal1 segments={len(clk)}")

    # Only vertical clock stubs can cross a tap; index them by x.
    vstubs = [(x1, y1, x2, y2) for _w, x1, y1, x2, y2 in clk if x1 == x2]
    print(f"vertical clock stubs={len(vstubs)}")

    # Build tap rectangles for every instance, bucketed by row.
    by_row = defaultdict(list)
    for inst, cell, x, y, orient in comps:
        w, h = cells[cell]["size"]
        for pin, x0, y0, x1, y1 in cells[cell]["supply"]:
            tx0, ty0, tx1, ty1 = transform(x0, y0, x1, y1, w, h, orient)
            # The band part is the 600 dbu around a row edge; keep only the tap.
            if ty0 < 0 or ty1 > h:
                continue                        # the part outside the cell box is the band
            by_row[y].append((pin, x + tx0, y + ty0, x + tx1, y + ty1, inst, cell, orient))

    print(f"instances with a real tap: {sum(len(v) for v in by_row.values())}")
    hits = []
    half = args.width // 2
    for x1, y1, x2, y2 in vstubs:
        lo_y, hi_y = min(y1, y2), max(y1, y2)
        # a stub can reach a tap in the row it belongs to and the neighbouring row
        for ry in {lo_y - ROW_H, lo_y, hi_y - ROW_H, hi_y}:
            for pin, tx0, ty0, tx1, ty1, inst, cell, orient in by_row.get(ry, ()):
                if tx1 <= x1 - half or tx0 >= x1 + half:
                    continue
                if ty1 <= lo_y or ty0 >= hi_y:
                    continue
                hits.append((x1, y1, y2, pin, tx0, ty0, tx1, ty1, inst, cell, orient))

    print(f"clock stubs overlapping a supply tap: {len(hits)}")
    for h in hits[:args.limit]:
        x1, y1, y2, pin, tx0, ty0, tx1, ty1, inst, cell, orient = h
        print(f"\n  clock metal1 x={x1} y {y1}..{y2} ({(y2 - y1) / 2000:.3f} um) "
              f"at ({x1 / 2000:.3f},{y1 / 2000:.3f})")
        print(f"  {pin} tap x {tx0}..{tx1} y {ty0}..{ty1} of {inst} {cell} {orient} "
              f"= ({tx0 / 2000:.3f}..{tx1 / 2000:.3f}, {ty0 / 2000:.3f}..{ty1 / 2000:.3f}) um")
    print(f"\nstubs near a tap: {len({h[0] for h in hits})}")


if __name__ == "__main__":
    main()
