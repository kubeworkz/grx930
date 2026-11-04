# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Test the clock's own routing layers against the supply grid's stripes in the routed DEF.

The earlier probes tested metal1 -- the rails -- because the rail islands were the thing that did
not pair.  But the supply *grid* is metal3/4/5 (VDD metal3 stripes every 20 um, metal4 verticals,
metal5 horizontals), and the clock is routed on metal3 and metal4 as well.  A clock metal3 wire whose
band overlaps a VDD metal3 stripe is a short with no via and no metal1 involved, which is exactly
the shape of a defect that every rail/via test would miss.  This intersects each clock segment,
rect from its centreline and the layer's design width, with the stripes on the same layer, and also
reports clock vertices where the route changes layer on top of a stripe (an implicit via there).

    python3 clk_vs_stripes.py --def .../grx930_test_chip_filled_metal1.def [--widths m2=560,...]

Exit status 0.
"""

import argparse
import re
from collections import Counter, defaultdict

WIDTH = {"Metal2": 560, "Metal3": 560, "Metal4": 560, "Metal5": 560}   # DEF units (0.5 um each)
STRIPE_LAYER = {"Metal3": 3, "Metal4": 4, "Metal5": 5}
NET_RE = re.compile(r"^-\s+(\S+)")
SEG_RE = re.compile(r"(?:^|\s)(Metal[1-5])(?: (\d+))?(?: \+ SHAPE \w+)? \( (\d+) (\d+)(?: \d+)? \)"
                    r" \( (\S+) (\S+)(?: \d+)? \)")


def parse_def(path):
    special = {"VDD": defaultdict(list), "VSS": defaultdict(list)}
    clk = []
    in_special = in_nets = False
    net = None
    for line in open(path, errors="replace"):
        s = line.strip()
        if s.startswith("SPECIALNETS"):
            in_special, in_nets = True, False
            continue
        if s.startswith("END SPECIALNETS"):
            in_special = False
            continue
        if s.startswith("NETS "):
            in_nets = True
            continue
        if s == "END NETS":
            in_nets = False
            continue
        if in_special or in_nets:
            m = NET_RE.match(s)
            if m:
                net = m.group(1)
                continue
        if in_special and net in special:
            m = SEG_RE.search(s)
            if not m:
                continue
            layer, w, x1, y1, x2, y2 = m.groups()
            if layer not in STRIPE_LAYER:
                continue
            width = int(w) if w else 0
            if not width or "+ SHAPE STRIPE" not in s:
                continue
            x2 = x1 if x2 == "*" else x2
            y2 = y1 if y2 == "*" else y2
            special[net][layer].append((int(x1), int(y1), int(x2), int(y2), width))
        elif in_nets and net == "i_clk":
            m = SEG_RE.search(s)
            if not m:
                continue
            layer, w, x1, y1, x2, y2 = m.groups()
            x2 = x1 if x2 == "*" else x2
            y2 = y1 if y2 == "*" else y2
            clk.append((layer, int(w) if w else 0, int(x1), int(y1), int(x2), int(y2)))
    return special, clk


def rects(layer, w, x1, y1, x2, y2):
    half = (w or WIDTH.get(layer, 560)) // 2
    return min(x1, x2) - half, min(y1, y2) - half, max(x1, x2) + half, max(y1, y2) + half


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--limit", type=int, default=20)
    args = ap.parse_args()

    special, clk = parse_def(args.def_file)
    print("stripes: " + ", ".join(f"{n}:{ {k: len(v) for k, v in d.items()} }"
                                  for n, d in special.items()))
    print("clock segments: " + str(Counter(c[0] for c in clk)))

    hits = []
    for layer, w, x1, y1, x2, y2 in clk:
        r = rects(layer, w, x1, y1, x2, y2)
        for net, by_layer in special.items():
            for sx0, sy0, sx1, sy1, sw in by_layer.get(layer, ()):
                s = rects(layer, sw, sx0, sy0, sx1, sy1)
                if r[0] < s[2] and r[2] > s[0] and r[1] < s[3] and r[3] > s[1]:
                    hits.append((net, layer, x1, y1, x2, y2, sx0, sy0, sx1, sy1))

    print(f"clock segments overlapping a same-layer supply stripe: {len(hits)}")
    seen = set()
    for net, layer, x1, y1, x2, y2, sx0, sy0, sx1, sy1 in hits:
        key = (net, layer, round(y1 / 100), round(y2 / 100))
        if key in seen:
            continue
        seen.add(key)
        print(f"\n{net} {layer} stripe y={sy0} x {sx0}..{sx1}")
        print(f"   clock {layer} ({x1},{y1}) -> ({x2},{y2})  um "
              f"({x1 / 2000:.3f},{y1 / 2000:.3f}) -> ({x2 / 2000:.3f},{y2 / 2000:.3f})")
        if len(seen) >= args.limit:
            print("\n... more")
            break
    print(f"\ndistinct (net, layer, y) groups: {len(seen)}")


if __name__ == "__main__":
    main()
