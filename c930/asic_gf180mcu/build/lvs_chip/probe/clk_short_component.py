# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Find the metal1 component that carries both supply-rail metal and a via1.

In the pre-stitch die nothing reaches down to a rail: `clk_short_gds.py` finds zero via1 cuts on
any of the 971 VDD / 970 VSS islands, and `clk_short_def.py` finds the routed clock's own metal1
clear of every island.  So the clock and a rail meet through metal1 alone, and the component that
results is unique in the file: every normal rail island is metal1 that stops at the cell's tap, and
every normal cell pin is metal1 that carries a via1 but never reaches a row line.  A component that
holds both is the short.

    python3 clk_short_component.py --def ...filled_metal1.def --lef ...gf180mcu.lef \
        --gds ...stream_out_filled_metal1.gds [--limit 10]

Exit status 0.
"""

import argparse
import re
from bisect import bisect_left
from collections import defaultdict

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
    ap.add_argument("--limit", type=int, default=10)
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
    row_ys = sorted({y for _n, y in islands})

    ly = db.Layout()
    ly.read(args.gds)
    top = ly.top_cell()
    m1 = db.Region(top.begin_shapes_rec(ly.layer(34, 0)))
    v1 = db.Region(top.begin_shapes_rec(ly.layer(35, 0)))
    print(f"metal1 shapes={m1.count()} via1={v1.count()}", flush=True)
    merged = m1.merged()
    print(f"metal1 components={merged.count()}", flush=True)

    polys = []
    for p in merged.each():
        bb = p.bbox()
        if bb.height() < 2 * ROW_HALF + 2:      # cannot reach both sides of a band
            continue
        polys.append((bb, p))
    polys.sort(key=lambda t: t[0].bottom)
    bottoms = [t[0].bottom for t in polys]
    print(f"components tall enough to span a band: {len(polys)}", flush=True)

    via_pts = []
    for q in v1.each():
        bb = q.bbox()
        via_pts.append(((bb.left + bb.right) // 2, (bb.bottom + bb.top) // 2))
    print(f"via1 centres: {len(via_pts)}", flush=True)

    per = defaultdict(list)
    for cx, cy in via_pts:
        i = bisect_left(bottoms, cy - 10_000)
        j = i
        while j < len(polys) and polys[j][0].bottom <= cy:
            bb, p = polys[j]
            # Polygon containment, not bbox: a rail+tap polygon's bbox reaches far into the row
            # and would otherwise claim every via1 that merely sits beside it.
            if bb.left <= cx <= bb.right and bb.bottom <= cy <= bb.top and \
                    p.inside(db.Point(cx, cy)):
                per[j].append((cx, cy))
            j += 1

    print(f"components with a via1: {len(per)}", flush=True)
    hits = []
    for j, pts in per.items():
        bb, p = polys[j]
        # Row lines whose band lies inside the component's y extent.
        i = bisect_left(row_ys, bb.bottom + ROW_HALF)
        on_rail = []
        while i < len(row_ys) and row_ys[i] <= bb.top - ROW_HALF:
            on_rail.append(row_ys[i])
            i += 1
        if not on_rail:
            continue
        hit = []
        for y in on_rail:
            for net in ("VDD", "VSS"):
                for x0, x1 in islands.get((net, y), []):
                    if x0 <= bb.right and bb.left <= x1:
                        hit.append((net, y, x0, x1))
        if hit:
            hits.append((bb, p, pts, hit))
    print(f"components with both a via1 and rail-band metal: {len(hits)}", flush=True)
    for bb, p, pts, hit in hits:
        print(f"\nCOMPONENT bbox {bb} ({(bb.right - bb.left) / 1000:.2f} x "
              f"{(bb.top - bb.bottom) / 1000:.2f} um) area={p.area()} via1s={len(pts)}",
              flush=True)
        for net, y, x0, x1 in hit:
            print(f"   band y {y} row {(y - Y0) // ROW_H} {net} island x {x0}..{x1} "
                  f"({(x1 - x0) / 1000:.2f} um)", flush=True)
        for cx, cy in pts[:4]:
            own = [t for t in comps
                   if t[2] <= cx < t[2] + t[4] and t[3] <= cy < t[3] + t[5]]
            print(f"   via1 at ({cx},{cy}) row {(cy - Y0) // ROW_H}", flush=True)
            for inst, cell, x, yy, w, h, orient in own:
                print(f"      cell {inst} {cell} {orient} at ({x},{yy}) size {w}x{h}", flush=True)
    if len(hits) > args.limit:
        print(f"\n... {len(hits) - args.limit} more components not printed")


if __name__ == "__main__":
    main()
