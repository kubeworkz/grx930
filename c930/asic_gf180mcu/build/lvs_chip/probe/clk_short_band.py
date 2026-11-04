# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Find every metal1 shape that enters a supply rail band in the streamed die.

Two measurements narrow the clock-to-rail contact to the drawn metal1.  `clk_short_def.py`: the
routed DEF's clock metal1 is clear of every rebuilt island.  `clk_short_gds.py`: the pre-stitch
GDS has no via1 on a rail at all.  So the contact is a metal1 shape that reaches into a band --
not a via, not the DEF's routing.  The bands are rebuilt from the DEF (971 VDD / 970 VSS, the
census counts), **shrunk by 2 dbu**, so a cell pin that merely abuts a band edge (the VSS tab of
every cell starts exactly at 0.300 um) is not reported; only a shape that overlaps the band's
interior is.

    python3 clk_short_band.py --def ...filled_metal1.def --lef ...gf180mcu.lef \
        --gds ...stream_out_filled_metal1.gds [--window x0 y0 x1 y1]

Exit status 0.
"""

import argparse
import re
from collections import defaultdict

import klayout.db as db

ROW_HALF = 300
ROW_H = 3920
Y0 = 11_760
UPRIGHT = ("N", "FN")
SHRINK = 2

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
            sizes[name] = (round(float(m.group(1)) * 1000), round(float(m.group(2)) * 1000))
        if name and s == "END " + name:
            name = None
    return sizes


def model(def_file, sizes):
    comps, bands = [], defaultdict(list)
    for line in open(def_file, errors="replace"):
        m = COMP_RE.match(line.strip())
        if not m:
            continue
        inst, cell, x, y, orient = m.group(1), m.group(2), int(m.group(3)), int(m.group(4)), m.group(5)
        w, h = sizes.get(cell, (0, 0))
        x, y = x // 2, y // 2
        comps.append((inst, cell, x, y, w, h, orient))
        up = orient in UPRIGHT
        bands[("VDD", y + (h if up else 0))].append((x, x + w, inst))
        bands[("VSS", y + (0 if up else h))].append((x, x + w, inst))
    islands = {}
    for key, items in bands.items():
        runs = []
        for x0, x1, inst in sorted(items)[:]:  # keep inst per interval below
            if runs and x0 <= runs[-1][1]:
                runs[-1][1] = max(runs[-1][1], x1)
                runs[-1][2].append(inst)
            else:
                runs.append([x0, x1, [inst]])
        islands[key] = runs
    return comps, islands


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--lef", required=True)
    ap.add_argument("--gds", required=True)
    ap.add_argument("--window", nargs=4, type=int, default=None,
                    help="x0 y0 x1 y1 in GDS dbu, to limit the metal1 region")
    ap.add_argument("--limit", type=int, default=40)
    args = ap.parse_args()

    sizes = lef_sizes(args.lef)
    comps, islands = model(args.def_file, sizes)
    band = db.Region()
    owner = []
    for (net, y), runs in islands.items():
        for x0, x1, insts in runs:
            b = db.Box(x0, y - ROW_HALF, x1, y + ROW_HALF)
            b = db.Box(b.left + SHRINK, b.bottom + SHRINK, b.right - SHRINK, b.top - SHRINK)
            if b.empty():
                continue
            band.insert(b)
            owner.append((net, y, x0, x1, b, insts))

    ly = db.Layout()
    ly.read(args.gds)
    top = ly.top_cell()
    m1 = db.Region(top.begin_shapes_rec(ly.layer(34, 0)))
    if args.window:
        m1 &= db.Region(db.Box(*args.window))
    print(f"metal1 shapes={m1.count()}  rail-band boxes={len(owner)}  shrunk by {SHRINK} dbu",
          flush=True)
    hits = m1 & band
    print(f"metal1 pieces inside a band interior: {hits.count()}", flush=True)

    buckets = defaultdict(list)
    for p in hits.each():
        bb = p.bbox()
        cx = (bb.left + bb.right) // 2
        for net, y, x0, x1, b, insts in owner:
            if x0 <= cx <= x1 and b.bottom <= bb.bottom and bb.top <= b.top + 2 and \
                    bb.bottom >= b.bottom - 2:
                buckets[(net, y, x0, x1)].append((bb, p.area()))
                break
    print(f"bands with an intrusion: {len(buckets)}", flush=True)
    for (net, y, x0, x1), shapes in sorted(buckets.items(), key=lambda kv: -len(kv[1]))[:args.limit]:
        insts = [t[2] for t in owner if t[0] == net and t[1] == y and t[2] == x0 and t[3] == x1]
        names = insts[0][:6] if insts else []
        row = (y - Y0) // ROW_H
        print(f"\n{net} row {row} band y {y} island x {x0}..{x1} ({(x1 - x0) / 1000:.2f} um) "
              f"shapes={len(shapes)}")
        if names:
            print(f"  island cells: {names} ...")
        for bb, a in sorted(shapes, key=lambda t: -t[1])[:6]:
            ccx = (bb.left + bb.right) // 2
            own = [t for t in comps if t[2] <= ccx < t[2] + t[4] and t[3] <= bb.center().y < t[3] + t[5]]
            print(f"  metal1 {bb} ({(bb.right - bb.left) / 1000:.2f} x {(bb.top - bb.bottom) / 1000:.2f} um)"
                  f" area={a}")
            for inst, cell, x, yy, w, h, orient in own:
                print(f"      cell {inst} {cell} {orient} at ({x},{yy}) size {w}x{h}")


if __name__ == "__main__":
    main()
