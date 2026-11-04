# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Locate the clock-to-rail contact in the streamed GDS, using the DEF's rail model.

`clk_short_def.py` shows the routed DEF's own metal1 never faults a rail: all 229 clock metal1
stubs are clear of every rebuilt island.  The comparison is run on the streamed GDS, so the
question becomes which drawn shape connects the two.  This intersects the drawn via1 cuts with the
rail bands the DEF describes -- in the pre-stitch file nothing should be there (the math in
doc/lvs_plan.md: the strap pass is the first thing to place a via1 on a rail), so a hit is the
contact, with the island's x range and the instance standing on it.

    python3 clk_short_gds.py --def .../grx930_test_chip_filled_metal1.def \
        --lef .../gf180mcu_fd_sc_mcu7t5v0.lef --gds .../stream_out_filled_metal1.gds

Exit status 0; a printed HIT block is the finding.
"""

import argparse
import re
from collections import defaultdict

import klayout.db as db

ROW_HALF = 300          # GDS dbu: 0.3 um at 1 nm/dbu
ROW_H = 3920            # GDS dbu: 3.92 um row pitch
Y0 = 11_760             # ROW_0 in GDS dbu (23,520 DEF units)
UPRIGHT = ("N", "FN")

ROW_RE = re.compile(r"^ROW\s+(\S+)\s+\S+\s+(\d+)\s+(\d+)\s+(\w+)\s+DO")
COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)")


def lef_sizes(path):
    sizes, name = {}, None
    for line in open(path, errors="replace"):
        s = line.strip()
        m = re.match(r"MACRO (\S+)", s)
        if m:
            name = m.group(1)
            continue
        m = re.match(r"SIZE ([\d.]+) BY ([\d.]+)", s)
        if m and name:
            # DEF units are 2 per GDS dbu
            sizes[name] = (round(float(m.group(1)) * 1000), round(float(m.group(2)) * 1000))
        if name and s == "END " + name:
            name = None
    return sizes


def parse_def(path, sizes):
    comps, islands = [], defaultdict(list)
    for line in open(path, errors="replace"):
        m = COMP_RE.match(line.strip())
        if not m:
            continue
        inst, cell, x, y, orient = m.group(1), m.group(2), int(m.group(3)), int(m.group(4)), m.group(5)
        w, h = sizes.get(cell, (0, 0))   # LEF micrometres -> GDS dbu (1 nm)
        # DEF units are 2 per GDS dbu (2,000/um against 1,000/um)
        x, y = x // 2, y // 2
        comps.append((inst, cell, x, y, w, h, orient))
        up = orient in UPRIGHT
        islands[("VDD", y + (h if up else 0))].append((x, x + w))
        islands[("VSS", y + (0 if up else h))].append((x, x + w))
    merged = {}
    for key, items in islands.items():
        runs = []
        for x0, x1 in sorted(items):
            if runs and x0 <= runs[-1][1]:
                runs[-1][1] = max(runs[-1][1], x1)
            else:
                runs.append([x0, x1])
        merged[key] = runs
    return comps, merged


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--lef", required=True)
    ap.add_argument("--gds", required=True)
    args = ap.parse_args()

    sizes = lef_sizes(args.lef)
    comps, islands = parse_def(args.def_file, sizes)
    nv = sum(1 for k in islands if k[0] == "VDD")
    ns = sum(len(v) for k, v in islands.items() if k[0] == "VDD")
    print(f"model: VDD boundaries={nv} islands={ns} "
          f"(census says 971); VSS islands={sum(len(v) for k, v in islands.items() if k[0] == 'VSS')}")

    ly = db.Layout()
    ly.read(args.gds)
    top = ly.top_cell()
    v1 = db.Region(top.begin_shapes_rec(ly.layer(35, 0)))
    print(f"gds: {args.gds} via1 shapes={v1.count()}")

    for net in ("VDD", "VSS"):
        rail = db.Region()
        for (n, y), runs in islands.items():
            if n != net:
                continue
            for x0, x1 in runs:
                rail.insert(db.Box(x0, y - ROW_HALF, x1, y + ROW_HALF))
        hits = v1 & rail
        print(f"{net}: rail area {rail.area()} dbu^2, via1 pieces on it={hits.count()}")
        seen = 0
        for p in hits.each():
            bb = p.bbox()
            cy = max(y for (n, y), runs in islands.items() if n == net
                     for x0, x1 in runs if x0 <= bb.center().x <= x1
                     and abs(bb.center().y - y) <= ROW_HALF)
            cx = bb.center().x
            owner = [t for t in comps
                     if t[2] <= cx < t[2] + t[4] and
                     (t[3] <= bb.center().y < t[3] + t[5])]
            print(f"  HIT {net} via1 bbox {bb} centre ({cx},{bb.center().y}) "
                  f"row line {cy} row {(cy - Y0) // ROW_H}")
            for inst, cell, x, y, w, h, orient in owner:
                print(f"      cell {inst} {cell} {orient} at ({x},{y}) size {w}x{h}")
            for (n, y), runs in islands.items():
                if n == net and y == cy:
                    for x0, x1 in runs:
                        if x0 <= cx <= x1:
                            print(f"      island x {x0}..{x1} ({(x1 - x0) / 1000:.2f} um)")
            seen += 1
            if seen > 40:
                print("  ... (more hits truncated)")
                break


if __name__ == "__main__":
    main()
