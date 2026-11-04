# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Find which clock wiring stub lands on which supply rail island in the routed DEF.

Why this exists: the stitched-die comparison puts the clock on the VDD net, and the pre-stitch
census showed the clock net already carried one rail island's worth of VDD terminals (496).  The
clock's metal1 wiring is only 229 segments of 17,641 -- pin-access stubs that run from a metal2
wire down to a cell pin -- and 96 of them cross a row boundary, which in this PDK is a supply rail
band (metal1, 0.6 um tall, centred on the row line).  Most of those cross in empty rows where no
cell means no rail.  This script rebuilds the rail islands from the DEF alone (cell box + the
VDD-is-top rule) and intersects them with the clock's metal1 segments, so the answer is a named
cell and a named island rather than a guess.

    python3 clk_short_def.py --def .../grx930_test_chip_filled_metal1.def \
        --lef .../gf180mcu_fd_sc_mcu7t5v0.lef

Output is one line per contact plus the island and neighbour instances.  Exit status 0.
"""

import argparse
import re
from collections import defaultdict

ROW_RE = re.compile(r"^ROW\s+(\S+)\s+\S+\s+(\d+)\s+(\d+)\s+(\w+)\s+DO\s+(\d+)\s+BY\s+1\s+STEP\s+(\d+)")
COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)")
ROW_HALF = 600          # 0.3 um either side of a row line, in DEF units (2000 / um)
UPRIGHT = ("N", "FN")


def lef_sizes(path):
    sizes = {}
    name = None
    for line in open(path, errors="replace"):
        s = line.strip()
        m = re.match(r"MACRO (\S+)", s)
        if m:
            name = m.group(1)
            continue
        m = re.match(r"SIZE ([\d.]+) BY ([\d.]+)", s)
        if m and name:
            sizes[name] = (round(float(m.group(1)) * 2000), round(float(m.group(2)) * 2000))
        if s.startswith("END " + (name or "")) and name:
            name = None
    return sizes


def parse_def(path):
    rows, comps = [], []
    net = None
    in_nets = False
    clk = []
    for line in open(path, errors="replace"):
        s = line.strip()
        m = ROW_RE.match(s)
        if m:
            rows.append((m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)))
            continue
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
        if not m:
            continue
        layer, w, x1, y1, x2, y2 = m.groups()
        if layer != "Metal1":
            continue
        # DEF writes a wildcard for "same as the previous point" in either axis, so a horizontal
        # run is ( x1 y ) ( x2 * ) -- dropping that form loses every horizontal segment.
        x2 = x1 if x2 == "*" else x2
        y2 = y1 if y2 == "*" else y2
        clk.append((int(w) if w else None, int(x1), int(y1), int(x2), int(y2)))
    return rows, comps, clk


def merge_intervals(items):
    runs = []
    for x0, x1 in sorted(items):
        if runs and x0 <= runs[-1][1]:
            runs[-1][1] = max(runs[-1][1], x1)
        else:
            runs.append([x0, x1])
    return [(a, b) for a, b in runs]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--lef", required=True)
    args = ap.parse_args()

    sizes = lef_sizes(args.lef)
    rows, comps, clk = parse_def(args.def_file)
    print(f"rows={len(rows)} components={len(comps)} i_clk metal1 segments={len(clk)}")

    bands = defaultdict(list)     # (net, y) -> [x0, x1, cell, inst]
    for inst, cell, x, y, orient in comps:
        if cell not in sizes:
            print(f"  (no LEF size for {cell})")
            continue
        w, h = sizes[cell]
        upright = orient in UPRIGHT
        bands[("VDD", y + (h if upright else 0))].append((x, x + w, cell, inst))
        bands[("VSS", y + (0 if upright else h))].append((x, x + w, cell, inst))

    islands = {}
    for key, items in bands.items():
        for x0, x1 in merge_intervals([(a, b) for a, b, _c, _i in items]):
            islands[key] = islands.get(key, []) + [(x0, x1)]

    # A cell pin of (x, y) sits in the cell whose box contains that point.
    def cell_at(px, py):
        for inst, cell, x, y, orient in comps:
            w, h = sizes.get(cell, (0, 0))
            if x <= px < x + w and y <= py < y + h:
                return inst, cell, orient
        return None

    contacts = []
    for w, x1, y1, x2, y2 in clk:
        for k in range(int((min(y1, y2) - 23520) // 7840) - 1,
                       int((max(y1, y2) - 23520) // 7840) + 2):
            yrow = 23520 + k * 7840
            if not (yrow - ROW_HALF <= max(y1, y2) and yrow + ROW_HALF >= min(y1, y2)):
                continue
            for net in ("VDD", "VSS"):
                for ix0, ix1 in islands.get((net, yrow), []):
                    lo, hi = min(x1, x2), max(x1, x2)
                    if lo <= ix1 and hi >= ix0:
                        contacts.append((net, yrow, ix0, ix1, x1, y1, x2, y2, w))

    print(f"contacts on a rail island: {len(contacts)}")
    for net, yrow, ix0, ix1, x1, y1, x2, y2, w in sorted(contacts):
        mx, my = (x1 + x2) // 2, (y1 + y2) // 2
        near = cell_at(mx, my) or cell_at(x1, y1) or cell_at(x2, y2)
        print(f"\n{net} island x {ix0}..{ix1} ({(ix1 - ix0) / 2000:.2f} um) at row line {yrow} "
              f"(row {(yrow - 23520) // 7840})")
        print(f"  clock metal1 {x1},{y1} -> {x2},{y2} (width={w}) "
              f"um ({x1 / 2000:.3f},{y1 / 2000:.3f}) -> ({x2 / 2000:.3f},{y2 / 2000:.3f})")
        print(f"  inside island: x {x1 >= ix0 and x1 <= ix1}, y in band "
              f"{yrow - ROW_HALF <= y1 <= yrow + ROW_HALF}")
        if near:
            print(f"  cell at that point: {near[0]} {near[1]} {near[2]}")
        # neighbours of the contact along the island
        edge = [t for t in bands.get((net, yrow), []) if t[0] <= mx < t[1]]
        for inst, cell, x, y, orient in comps:
            ww, hh = sizes.get(cell, (0, 0))
            if x <= mx < x + ww and abs((y if orient in UPRIGHT else y + hh) - yrow) < 2:
                print(f"  rail owner row: {inst} {cell} {orient} at ({x},{y})")
    print("\nELAPSED done")


if __name__ == "__main__":
    main()
