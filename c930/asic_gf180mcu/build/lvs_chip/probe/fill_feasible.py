#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""How much of the empty row area is actually free of metal1 routing?

The first fill pass tiled every empty site and shorted the supplies: 10,093 rail/route overlaps
(fill_route_short.py). A legal pass may only fill sites no metal1 route crosses. This measures the
consequence before paying for another extraction: per gap, how many sites are free, how many gaps
are blocked entirely, and how long the longest free run is.

    python3 fill_feasible.py [--def FILE]

Read-only.
"""

import argparse
import re
from collections import Counter, defaultdict

DEF = "/work/c930/asic_gf180mcu/build/lvs_chip/filled/grx930_test_chip_filled.def"
LEF = "/work/c930/asic_gf180mcu/build/cells.lef"
UM = 2000.0
HALF = 230            # metal1 route half width, DEF units
SITE = 1120
H = 7840

ROW_RE = re.compile(r"^ROW\s+\S+\s+\S+\s+(\d+)\s+(\d+)\s+(\w+)")
POINT_RE = re.compile(r"\(\s*(\*|-?\d+)\s+(\*|-?\d+)\s*\)")
COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+\w+\s+\(\s*(\d+)\s+(\d+)\s*\)")


def lef_sizes(path):
    text = open(path, errors="replace").read()
    out = {}
    for m in re.finditer(r"^MACRO\s+(\S+)\n(.*?)^END\s+\1", text, re.S | re.M):
        s = re.search(r"^\s*SIZE\s+([\d.]+)\s+BY", m.group(2), re.M)
        if s:
            out[m.group(1)] = float(s.group(1))
    return out


def parse(path):
    rows, comps, segs = {}, [], []
    in_comp = in_nets = False
    net = layer = None
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
                m = COMP_RE.match(s)
                if m:
                    comps.append((m.group(1), m.group(2), int(m.group(3)), int(m.group(4))))
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
            w = s.split()
            if w and w[0].lstrip("+") in ("ROUTED", "NEW"):
                rest = s.split(w[0], 1)[1].strip()
                layer = rest.split()[0] if rest else ""
                points = POINT_RE.findall(rest) if layer == "Metal1" else []
            elif layer == "Metal1" and POINT_RE.search(s):
                points += POINT_RE.findall(s)
            else:
                continue
            if layer == "Metal1" and len(points) >= 2:
                px = py = None
                pts = []
                for a, b in points:
                    x = px if a == "*" else int(a)
                    y = py if b == "*" else int(b)
                    px, py = x, y
                    pts.append((x, y))
                for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
                    if x0 == x1 and y0 == y1:
                        continue
                    segs.append((net, min(x0, x1) - HALF, min(y0, y1) - HALF,
                                 max(x0, x1) + HALF, max(y0, y1) + HALF))
            points = []
    return rows, comps, segs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", default=DEF)
    ap.add_argument("--lef", default=LEF)
    args = ap.parse_args()
    rows, comps, segs = parse(args.def_file)
    sizes = lef_sizes(args.lef)
    print(f"rows={len(rows)} components={len(comps)} metal1-segments={len(segs)}")

    bands = defaultdict(list)
    for _net, x0, y0, x1, y1 in segs:
        for k in range(y0 // 1000, y1 // 1000 + 1):
            bands[k].append((x0, x1, y0, y1))

    def overlaps(x, y, w, ry0, ry1):
        for k in range(ry0 // 1000, ry1 // 1000 + 1):
            for sx0, sx1, sy0, sy1 in bands.get(k, ()):
                if sx0 < x + w and sx1 > x and sy0 < ry1 and sy1 > ry0:
                    return True
        return False

    def blocked(x, y, w):
        # Rails occupy the 0.6 um band on each row edge; fill_* cells draw no other metal1.
        return overlaps(x, y, w, y - 600, y + 600) or \
               overlaps(x, y, w, y + H - 600, y + H + 600)

    def tie_ok(x, y, w):
        # filltie adds two vertical metal1 stubs inside the box, so its whole box must be clear.
        return not overlaps(x, y, w, y, y + H)

    occ = defaultdict(list)
    for inst, cell, x, y in comps:
        if not inst.startswith("FILL_"):
            occ[y].append((x, x + int(round(sizes[cell] * UM))))
    print(f"placed rows={len(occ)}")

    gaps = free = blocked_sites = 0
    fully = 0
    tieable = 0
    runs = Counter()
    for y in occ:
        iv = sorted(occ[y])
        for (a0, a1), (b0, _b1) in zip(iv, iv[1:]):
            n = (b0 - a1) // SITE
            if n <= 0:
                continue
            gaps += 1
            run = 0
            anyfree = 0
            for i in range(n):
                if blocked(a1 + i * SITE, y, SITE):
                    blocked_sites += 1
                    if run:
                        runs[run] += 1
                    run = 0
                else:
                    free += 1
                    anyfree += 1
                    run += 1
                    if tie_ok(a1 + i * SITE, y, SITE):
                        tieable += 1
            if run:
                runs[run] += 1
            if not anyfree:
                fully += 1
    total = free + blocked_sites
    print(f"gap sites={total} free={free} ({100.0*free/total:.1f}%) blocked={blocked_sites} "
          f"tie-capable={tieable} ({100.0*tieable/total:.1f}%)")
    print(f"gaps={gaps} fully blocked={fully} ({100.0*fully/gaps:.1f}%)")
    print(f"free runs: {len(runs)}; longest {max(runs) if runs else 0} sites, "
          f"median {sorted(runs)[len(runs)//2] if runs else 0}")
    print("run-length histogram (sites): " + ", ".join(
        f"{k}:{v}" for k, v in sorted(runs.items())[:12]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
