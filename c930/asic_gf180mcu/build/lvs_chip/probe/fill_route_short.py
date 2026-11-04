#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Does the filler's metal1 rail geometry collide with metal1 routing?

The filled die's census shows the VDD and VSS labels on one net, which is a short. The filler adds
metal1 rails across sites that had no cell, so the suspect is routing that used those empty sites
and now sits under a rail. This checks it against the DEF alone:

  * every FILL_* instance's rail rectangles (VDD at the row's top or bottom edge, VSS at the other,
    per the row's orientation) are tested against every Metal1 NETS segment, expanded to the
    0.23 um route width;
  * the same segments' distance to the nearest row boundary is histogrammed: a router that respected
    the rails would keep metal1 out of the 0.6 um band the rails occupy.

    python3 fill_route_short.py [--def FILE]

Exit status: 0 report written, 2 refused.
"""

import argparse
import re
import sys
from collections import Counter, defaultdict

DEF = "/work/c930/asic_gf180mcu/build/lvs_chip/filled/grx930_test_chip_filled.def"
LEF = "/work/c930/asic_gf180mcu/build/cells.lef"
UM = 2000.0           # DEF distance units per micron
H = 7840              # cell height in units (3.92 um)
RAIL = 600            # rail half-height in units (0.3 um)
WIDTH = 460           # metal1 route width in units (0.23 um)
HALF = WIDTH // 2

ROW_RE = re.compile(r"^ROW\s+\S+\s+\S+\s+(\d+)\s+(\d+)\s+(\w+)")
POINT_RE = re.compile(r"\(\s*(\*|-?\d+)\s+(\*|-?\d+)\s*\)")


def parse(path):
    """(rows {y: orient}, fill [(x, y, w)], [(net, [(x0,y0),(x1,y1)])])."""
    rows = {}
    fills = []
    segs = []
    in_comp = in_nets = False
    net = None
    layer = None
    points = []
    with open(path, errors="replace") as fh:
        for line in fh:
            s = line.strip()
            m = ROW_RE.match(s)
            if m:
                rows[int(m.group(2))] = (m.group(3), int(m.group(1)))
                continue
            if s.startswith("COMPONENTS"):
                in_comp = True
                continue
            if s.startswith("END COMPONENTS"):
                in_comp = False
                continue
            if in_comp:
                m = re.match(r"-\s+(FILL_\S+)\s+(\S+)\s+\+\s+\w+\s+\(\s*(\d+)\s+(\d+)\s*\)", s)
                if m:
                    fills.append((m.group(1), m.group(2), int(m.group(3)), int(m.group(4))))
                continue
            if s.startswith("NETS"):
                in_nets = True
                continue
            if s.startswith("END NETS"):
                in_nets = False
                continue
            if not in_nets:
                continue
            if s.startswith("- "):
                net = s.split()[1]
                layer = None
                continue
            word = s.split()
            if word and word[0].lstrip("+") in ("ROUTED", "NEW"):
                rest = s.split(word[0], 1)[1].strip()
                name = rest.split()[0] if rest else ""
                layer = name if name.startswith("Metal") else None
                points = POINT_RE.findall(rest)
            elif layer == "Metal1" and POINT_RE.search(s):
                points += POINT_RE.findall(s)
            else:
                continue
            if layer == "Metal1" and len(points) >= 2:
                pts = []
                px = py = None
                for a, b in points:
                    x = px if a == "*" else int(a)
                    y = py if b == "*" else int(b)
                    px, py = x, y
                    pts.append((x, y))
                for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
                    if x0 == x1 and y0 == y1:
                        continue
                    segs.append((net, x0, y0, x1, y1))
            points = []
    return rows, fills, segs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", default=DEF)
    args = ap.parse_args()
    rows, fills, segs = parse(args.def_file)
    if not rows or not fills or not segs:
        print(f"REFUSED  rows={len(rows)} fills={len(fills)} metal1-segments={len(segs)}")
        return 2
    print(f"rows={len(rows)} fill-cells={len(fills)} metal1-segments={len(segs)}")

    y0 = min(rows)
    pitch = sorted(rows)[1] - sorted(rows)[0]
    hist = Counter()
    near = 0
    for _net, _x0, a, _x1, b in segs:
        for y in {a, b}:
            off = abs((y - y0) % pitch)
            off = min(off, pitch - off)
            hist[int(off // 100)] += 1
            if off <= RAIL:
                near += 1
    total = sum(hist.values())
    print(f"metal1 endpoints within {RAIL/UM:.2f} um of a row boundary: {near} of {total}")
    print("distance bin (0.1 um): count")
    for k in sorted(hist):
        print(f"  {k/10:5.1f}-{(k+1)/10:5.1f}: {hist[k]}")

    # Rail rectangles per filler. Widths come from the cell name suffix (fill_N = N sites,
    # filltie = 2 sites), and the cell is 16 sites (3.92 um) tall.
    fixed = []
    for inst, cell, x, y in fills:
        orient = rows[y][0]
        m = re.search(r"__fill_(\d+)$", cell)
        sites = int(m.group(1)) if m else (2 if cell.endswith("__filltie") else 0)
        if not sites:
            print(f"REFUSED  cannot size {inst} ({cell})")
            return 2
        fixed.append((inst, x, y, sites * 1120, orient))

    # Bucket route segments by y band so 100k fillers do not scan 290k segments each.
    bands = defaultdict(list)
    for net, ax, ay, bx, by in segs:
        ylo, yhi = min(ay, by) - HALF, max(ay, by) + HALF
        for k in range(ylo // 400, yhi // 400 + 1):
            bands[k].append((net, min(ax, bx) - HALF, ylo, max(ax, bx) + HALF, yhi))

    hits = Counter()
    examples = []
    for name, x, y, w, orient in fixed:
        # N rows: VDD at the top edge, VSS at the bottom. FS rows: the mirror image.
        if orient == "N":
            boxes = (("VDD", y + H - 600, y + H + 600), ("VSS", y - 600, y + 600))
        else:
            boxes = (("VDD", y - 600, y + 600), ("VSS", y + H - 600, y + H + 600))
        for supply, ry0, ry1 in boxes:
            for k in range(ry0 // 400, ry1 // 400 + 1):
                for net, lx0, ly0, lx1, ly1 in bands.get(k, ()):
                    if lx0 < x + w and lx1 > x and ly0 < ry1 and ly1 > ry0:
                        hits[net] += 1
                        if len(examples) < 6:
                            examples.append((name, supply, net, x, y))
    print(f"rail/route overlaps: {sum(hits.values())} over {len(hits)} nets")
    for net, n in hits.most_common(8):
        print(f"  net {net}: {n} rail overlaps")
    for name, supply, net, x, y in examples:
        print(f"  e.g. {name} {supply} rail at x={x} y={y} over net {net}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
