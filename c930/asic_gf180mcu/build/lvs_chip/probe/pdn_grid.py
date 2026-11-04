#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""The die's PDN grid as drawn, and which supply each stripe belongs to.

The routed DEF's SPECIALNETS and the artifact's geometry do not agree (the DEF lists 130 vertical
metal3 stripes per net that the GDS does not contain), so the grid is read from the GDS itself, and
the supply of each stripe family is taken from the net-name labels the streamer wrote on the same
metal. Prints, per layer: the distinct stripe centres, their pitch, and the labels sitting on them.

    python3 pdn_grid.py <die.gds>
"""

import sys
from collections import Counter

import klayout.db as db

path = sys.argv[1]
ly = db.Layout()
ly.read(path)
top = next(iter(ly.top_cells()))
print(f"{path}: dbu={ly.dbu} bbox={top.bbox()}")

FAMILIES = {"metal3": (42, 0), "metal4": (46, 0), "metal5": (81, 0)}


def long_stripes(layer, dt, min_len):
    """Stripes long enough to be PDN, as (orientation, centre, length) with a bbox."""
    li = ly.find_layer(layer, dt)
    reg = db.Region(top.begin_shapes_rec(li))
    horiz, vert = Counter(), Counter()
    for p in reg.merged().each():
        bb = p.bbox()
        if bb.height() <= 2000 and bb.width() >= min_len:
            horiz[bb.bottom] += 1
    for p in reg.merged().each():
        bb = p.bbox()
        if bb.width() <= 2000 and bb.height() >= min_len:
            vert[bb.left] += 1
    return horiz, vert


for name, (layer, dt) in FAMILIES.items():
    horiz, vert = long_stripes(layer, dt, 500_000)
    print(f"-- {name} {layer}/{dt}: {len(horiz)} horizontal positions, {len(vert)} vertical")
    for label, table in (("horizontal", horiz), ("vertical", vert)):
        if not table:
            continue
        ys = sorted(table)
        gaps = Counter(b - a for a, b in zip(ys, ys[1:]))
        print(f"   {label}: n={len(ys)} first={ys[:4]} last={ys[-2:]} "
              f"phase={ys[0]} gaps={gaps.most_common(4)}")

    # Labels on the same metal name the nets; a text's position sits on the shape it names.
    tl = ly.find_layer(layer, dt + 10)
    if tl is None:
        print(f"   no {layer}/{dt + 10} labels")
        continue
    texts = [(s.text.string, s.text.trans.disp) for s in top.shapes(tl).each()
             if s.is_text() and s.text is not None]
    counts = Counter(t for t, _ in texts)
    print(f"   labels: {len(texts)} total, {counts.most_common(6)}")
    for t, pos in texts[:12]:
        if t in ("VDD", "VSS"):
            print(f"     label {t} at ({pos.x},{pos.y})")
