# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Shape-level search for the clock-to-rail contact: metal1 that is not a rail but sits in one.

The band intersection by region (`clk_short_band.py`) returns the rail itself for every one of the
1,941 bands, which says nothing.  A rail rect is exactly 600 dbu tall and its edges sit exactly on
the band edges, so the discriminating test is per *shape*:

    height == 600 and bottom == y-300 and top == y+300   -> a rail rect (fine)
    anything else that overlaps a band's interior         -> an intrusion (the contact)

The band model comes from the DEF (971 VDD / 970 VSS islands, matching the census), so a hit also
names the island and the instances whose rails make it up.

    python3 clk_short_shapes.py --def ...filled_metal1.def --lef ...gf180mcu.lef \
        --gds ...stream_out_filled_metal1.gds [--limit 20]

Exit status 0.
"""

import argparse
import re
from bisect import bisect_left
from collections import Counter, defaultdict

import klayout.db as db

ROW_HALF = 300
ROW_H = 3920
Y0 = 11_760
UPRIGHT = ("N", "FN")
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--lef", required=True)
    ap.add_argument("--gds", required=True)
    ap.add_argument("--limit", type=int, default=20)
    args = ap.parse_args()

    sizes = lef_sizes(args.lef)
    comps, bands = [], defaultdict(list)
    for line in open(args.def_file, errors="replace"):
        m = COMP_RE.match(line.strip())
        if not m:
            continue
        inst, cell, x, y, orient = m.group(1), m.group(2), int(m.group(3)), int(m.group(4)), m.group(5)
        w, h = sizes.get(cell, (0, 0))
        x, y = x // 2, y // 2
        comps.append((inst, cell, x, y, w, h, orient))
        up = orient in UPRIGHT
        bands[("VDD", y + (h if up else 0))].append((x, x + w))
        bands[("VSS", y + (0 if up else h))].append((x, x + w))
    islands = {}
    for key, items in bands.items():
        runs = []
        for x0, x1 in sorted(items):
            if runs and x0 <= runs[-1][1]:
                runs[-1][1] = max(runs[-1][1], x1)
            else:
                runs.append([x0, x1])
        islands[key] = runs
    ys = sorted({y for _n, y in islands})
    print(f"islands: VDD {sum(len(v) for k, v in islands.items() if k[0] == 'VDD')}, "
          f"VSS {sum(len(v) for k, v in islands.items() if k[0] == 'VSS')}, "
          f"boundaries {len(ys)}", flush=True)

    ly = db.Layout()
    ly.read(args.gds)
    top = ly.top_cell()
    m1 = db.Region(top.begin_shapes_rec(ly.layer(34, 0)))
    print(f"metal1 shapes {m1.count()}", flush=True)

    hits = Counter()
    examples = defaultdict(list)
    checked = 0
    for p in m1.each():
        bb = p.bbox()
        checked += 1
        i = bisect_left(ys, bb.bottom - ROW_HALF)
        for j in (i - 1, i, i + 1):
            if j < 0 or j >= len(ys):
                continue
            y = ys[j]
            if bb.top <= y - ROW_HALF or bb.bottom >= y + ROW_HALF:
                continue
            is_rail = (bb.height() == 2 * ROW_HALF and bb.bottom == y - ROW_HALF
                       and bb.top == y + ROW_HALF)
            if is_rail:
                key = ("rail", y)
                continue
            cx = (bb.left + bb.right) // 2
            for net in ("VDD", "VSS"):
                for x0, x1 in islands.get((net, y), []):
                    if x0 <= cx <= x1:
                        key = (net, y, x0, x1)
                        hits[key] += 1
                        if len(examples[key]) < 6:
                            examples[key].append((bb, p.area()))
    print(f"shapes checked {checked}; bands with a non-rail shape overlapping the interior: "
          f"{len(hits)}", flush=True)
    for key, n in hits.most_common(args.limit):
        net, y, x0, x1 = key
        row = (y - Y0) // ROW_H
        print(f"\n{net} row {row} band y {y} island x {x0}..{x1} "
              f"({(x1 - x0) / 1000:.2f} um) shapes={n}")
        for bb, a in examples[key]:
            cx = (bb.left + bb.right) // 2
            own = [t for t in comps
                   if t[2] <= cx < t[2] + t[4] and t[3] <= bb.center().y < t[3] + t[5]]
            print(f"  metal1 {bb} {(bb.right - bb.left) / 1000:.2f} x "
                  f"{(bb.top - bb.bottom) / 1000:.2f} um area={a}")
            for inst, cell, x, yy, w, h, orient in own:
                print(f"      cell {inst} {cell} {orient} at ({x},{yy}) size {w}x{h}")


if __name__ == "__main__":
    main()
