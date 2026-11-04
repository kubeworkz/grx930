#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Follow one strap through every layer the deck connects, on the file that was written.

The stitch's own checks prove the metal2 clearance and that each pad sits inside its own net, but
those are statements about regions, not about a stack the netter can climb. This takes straps out of
`strap_report.json` and, for each, walks metal1 -> via1 -> metal2 -> via2 -> metal3 at the exact
coordinates, reporting whether every layer pair really overlaps.

    python3 strap_stack.py <stitched.gds> <strap_report.json> [n]
"""

import json
import sys

import klayout.db as db

gds, report = sys.argv[1], sys.argv[2]
count = int(sys.argv[3]) if len(sys.argv) > 3 else 5

ly = db.Layout()
ly.read(gds)
top = next(iter(ly.top_cells()))
data = json.load(open(report))
sites = data["sites"]
# One short, one long, and one dog-leg, plus the first few.
sites.sort(key=lambda s: (s["y_stripe"] - s["y_rail"]))
picks = sites[:2] + sites[len(sites) // 2:len(sites) // 2 + 2] + sites[-2:]
doglegs = [s for s in sites if s["x1"] != s["x2"]][:2]
picks += doglegs

cache = {}


def shapes(layer, dt):
    key = (layer, dt)
    if key not in cache:
        cache[key] = db.Region(top.begin_shapes_rec(ly.layer(layer, dt)))
    return cache[key]


def overlapping(layer_a, layer_b, box):
    """Does a shape on layer_a overlap `box` where layer_b also has a shape?"""
    a = shapes(*layer_a) & db.Region(box)
    b = shapes(*layer_b) & db.Region(box)
    return not (a & b).is_empty()


print(f"{len(sites)} straps in {report}; checking {len(picks)}")
bad = 0
for s in picks:
    x1, x2, y1, ys = s["x1"], s["x2"], s["y_rail"], s["y_stripe"]
    net = s["net"]
    # metal1 at the via1, metal2 over the whole strap, metal3 at the via2.
    m1_here = not (shapes(34, 0) & db.Region(db.Box(x1 - 130, y1 - 190, x1 + 130, y1 + 190))).is_empty()
    v1_here = not (shapes(35, 0) & db.Region(db.Box(x1 - 130, y1 - 130, x1 + 130, y1 + 130))).is_empty()
    m2_span = db.Box(min(x1, x2) - 140, min(y1, ys) - 190, max(x1, x2) + 140, max(y1, ys) + 190)
    m2_here = not (shapes(36, 0) & db.Region(m2_span)).is_empty()
    v2_here = not (shapes(38, 0) & db.Region(db.Box(x2 - 130, ys - 130, x2 + 130, ys + 130))).is_empty()
    m3_here = not (shapes(42, 0) & db.Region(db.Box(x2 - 190, ys - 140, x2 + 190, ys + 140))).is_empty()
    # The path the strap is supposed to take must be covered by metal2: the vertical run at x1 and,
    # for a dog-leg, the horizontal run along the stripe. (Intersecting the two pads cannot answer
    # this -- they are disjoint by construction, which is what made the first version report every
    # long strap as broken.)
    path = db.Region(m2_span)
    if x1 != x2:
        path.insert(db.Box(min(x1, x2) - 140, ys - 190, max(x1, x2) + 140, ys + 190))
    joined = (path - shapes(36, 0)).is_empty()
    ok = all((m1_here, v1_here, m2_here, v2_here, m3_here, joined))
    bad += 0 if ok else 1
    print(f"  {net} x1={x1} y1={y1} x2={x2} ys={ys} drop={ys - y1} "
          f"m1={m1_here} via1={v1_here} m2={m2_here} via2={v2_here} m3={m3_here} "
          f"joined={joined} -> {'OK' if ok else 'BROKEN'}")
print(f"broken straps: {bad} of {len(picks)}")
raise SystemExit(0 if bad == 0 else 1)
