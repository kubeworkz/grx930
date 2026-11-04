# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Every via1 cut that lands on a placed cell's supply tap, with the net the DEF routes there.

Why this test: the rail band is only the middle 0.6 um of a cell's supply pin.  The pin also has a
*tap* that runs up to 1.2 um into the row (dffq_1 VDD: 2.635..3.620; filltie: 1.930..3.920).  The
DEF band test and the via/band test both clear the clock, and the merged-metal1 components that
contain a via are too coarse (a rail+tap polygon reaches far).  A via1 cut inside a tap rectangle
is unambiguous: something dropped onto the supply pin above the band.

    python3 via_on_tap.py --def .../grx930_test_chip.def --lef ...gf180mcu.lef \
        --gds .../stream_out.gds [--grow 0]

Exit status 0.
"""

import argparse
import re
from collections import defaultdict

import klayout.db as db

COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)")
UPRIGHT = ("N", "FN")


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
        m = re.match(r"PIN (\S+)", s)
        if m:
            pin = m.group(1)
            continue
        if pin in ("VDD", "VSS"):
            m = re.match(r"RECT ([\-\d.]+) ([\-\d.]+) ([\-\d.]+) ([\-\d.]+)", s)
            if m:
                x0, y0, x1, y1 = (round(float(v) * 1000) for v in m.groups())
                cells[name]["supply"].append((pin, x0, y0, x1, y1))
    return cells


def transform(x0, y0, x1, y1, w, h, orient):
    if orient in UPRIGHT:
        if orient == "FN":
            x0, x1 = w - x1, w - x0
        return x0, y0, x1, y1
    nx0, nx1 = (w - x1, w - x0) if orient == "S" else (x0, x1)
    return nx0, h - y1, nx1, h - y0


def def_net_index(path):
    """{(rounded x, rounded y): net} for every Metal2 route vertex, to name the net at a via."""
    index = {}
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
        if "Metal2" not in s:
            continue
        t = s[8:] if s.startswith("+ ROUTED ") else (s[4:] if s.startswith("NEW ") else None)
        if t is None:
            continue
        m = re.match(r"Metal2(?: (\d+))?(?: \+ SHAPE \w+)? \( (\d+) (\d+)(?: \d+)? \)"
                     r" \( (\S+) (\d+)(?: \d+)? \)", t)
        if not m:
            continue
        w, x1, y1, x2, y2 = m.groups()
        x1, y1, y2 = int(x1), int(y1), int(y2)
        x2 = x1 if x2 == "*" else int(x2)
        # store at 0.5 um granularity, in GDS dbu
        for x, y in ((x1, y1), (x2, y2)):
            index[(x // 2 // 500, y // 2 // 500)] = net
    return index


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--lef", required=True)
    ap.add_argument("--gds", required=True)
    ap.add_argument("--grow", type=int, default=0, help="grow the tap before testing, dbu")
    ap.add_argument("--limit", type=int, default=40)
    args = ap.parse_args()

    cells = parse_lef(args.lef)
    instances = []
    for line in open(args.def_file, errors="replace"):
        m = COMP_RE.match(line.strip())
        if m:
            instances.append((m.group(1), m.group(2), int(m.group(3)) // 2, int(m.group(4)) // 2,
                              m.group(5)))
    print(f"cells={len(cells)} instances={len(instances)}")

    taps = db.Region()
    tap_owner = []
    owner_index = defaultdict(list)
    for inst, cell, x, y, orient in instances:
        w, h = cells[cell]["size"]
        for pin, x0, y0, x1, y1 in cells[cell]["supply"]:
            tx0, ty0, tx1, ty1 = transform(x0, y0, x1, y1, w, h, orient)
            if ty0 < 0 or ty1 > h:
                continue                    # the part outside the cell is the band, tested elsewhere
            b = db.Box(x + tx0, y + ty0, x + tx1, y + ty1)
            if args.grow:
                b = b.enlarged(args.grow)
            taps.insert(b)
            tap_owner.append((pin, b, inst, cell, orient, x, y))
    print(f"taps: {taps.count()} polygons (grow={args.grow})")

    ly = db.Layout()
    ly.read(args.gds)
    top = ly.top_cell()
    v1 = db.Region(top.begin_shapes_rec(ly.layer(35, 0)))
    hits = v1 & taps
    print(f"via1 cuts on a tap: {hits.count()}")

    net_index = def_net_index(args.def_file)
    print(f"DEF Metal2 vertices indexed: {len(net_index)}")

    out = []
    for p in hits.each():
        bb = p.bbox()
        cx, cy = (bb.left + bb.right) // 2, (bb.bottom + bb.top) // 2
        own = [t for t in tap_owner if t[1].contains(db.Point(cx, cy))]
        net = net_index.get((cx // 500, cy // 500))
        out.append((cx, cy, bb, net, own))
    out.sort(key=lambda t: (t[1], t[0]))
    for cx, cy, bb, net, own in out[:args.limit]:
        print(f"\nvia1 {bb} centre ({cx},{cy}) um ({cx / 1000:.3f},{cy / 1000:.3f}) "
              f"DEF net={net}")
        for pin, b, inst, cell, orient, x, y in own:
            print(f"   {pin} tap {b} of {inst} {cell} {orient} at ({x},{y})")
    if len(out) > args.limit:
        print(f"\n... {len(out) - args.limit} more")
    print(f"\ntotal via1-on-tap: {len(out)}")


if __name__ == "__main__":
    main()
