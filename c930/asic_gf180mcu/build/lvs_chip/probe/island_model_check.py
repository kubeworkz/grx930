#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Does the DEF+library rail model reproduce the die's metal1 islands?

The stitch treats an island as one maximal run of rail rects at one row boundary. That is only
useful if it is the same partition the deck's netter sees, so this clips the die's own metal1 to the
modelled VDD bands and counts merged components, then does the same with the model's own rects. If
the two counts agree, the model is the geometry; if they do not, the difference is where they part.

    python3 island_model_check.py
"""

import re
import sys
from collections import defaultdict

import klayout.db as db

ROOT = "/work/c930/asic_gf180mcu"
DEF = f"{ROOT}/build/lvs_chip/filled/grx930_test_chip_filled_metal1.def"
LIB = f"{ROOT}/build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds"
GDS = f"{ROOT}/build/lvs_chip/stream_out_filled_metal1.gds"
ROW_HALF = 300
FILLTIE = "gf180mcu_fd_sc_mcu7t5v0__filltie"

COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)"
                     r"\s+(\w+)")


def main():
    comps = []
    for line in open(DEF, errors="replace"):
        m = COMP_RE.match(line.strip())
        if m:
            comps.append((m.group(1), m.group(2), int(m.group(3)) // 2, int(m.group(4)) // 2,
                          m.group(5)))
    lib = db.Layout()
    lib.read(LIB)
    text_layer = lib.layer(34, 10)
    rails = {}
    for cell in {c[1] for c in comps}:
        c = lib.cell(cell)
        box = c.bbox(lib.layer(0, 0))
        h = box.height()
        pos = {}
        for s in c.shapes(text_layer).each():
            if s.is_text() and s.text is not None and s.text.string in ("VDD", "VSS"):
                pos[s.text.string] = s.text.trans.disp
        rails[cell] = (box.width(), h, {n: p.y > h // 2 for n, p in pos.items()})

    bands = defaultdict(list)
    for inst, cell, x, y, orient in comps:
        w, h, sides = rails[cell]
        upright = orient in ("N", "FN")
        for net in ("VDD", "VSS"):
            top_side = sides[net] if upright else not sides[net]
            cy = y + (h if top_side else 0)
            bands[(net, cy)].append((x, x + w))

    ly = db.Layout()
    ly.read(GDS)
    top = next(iter(ly.top_cells()))
    m1 = db.Region(top.begin_shapes_rec(ly.layer(34, 0)))

    for net in ("VDD", "VSS"):
        rects = db.Region()
        nrect = 0
        intervals = 0
        for (nm, cy), boxes in bands.items():
            if nm != net:
                continue
            boxes.sort()
            runs = []
            for x0, x1 in boxes:
                if runs and x0 <= runs[-1][1]:
                    runs[-1][1] = max(runs[-1][1], x1)
                else:
                    runs.append([x0, x1])
            intervals += len(runs)
            for x0, x1 in runs:
                rects.insert(db.Box(x0, cy - ROW_HALF, x1, cy + ROW_HALF))
                nrect += 1
        model = rects.merged()
        clipped = (m1 & rects).merged()
        print(f"{net}: boundaries={sum(1 for (n, _y) in bands if n == net)} "
              f"runs={intervals} rects={nrect} model_components={model.count()} "
              f"die_clipped_components={clipped.count()}")
        # Compare the two partitions' x extents on the three busiest boundaries.
        busiest = sorted((k for k in bands if k[0] == net),
                         key=lambda k: -sum(b[1] - b[0] for b in bands[k]))[:3]
        for key in busiest:
            cy = key[1]
            mm = (m1 & db.Region(db.Box(0, cy - ROW_HALF, 10 ** 9, cy + ROW_HALF))).merged()
            boxes = sorted(bands[key])
            runs = []
            for x0, x1 in boxes:
                if runs and x0 <= runs[-1][1]:
                    runs[-1][1] = max(runs[-1][1], x1)
                else:
                    runs.append([x0, x1])
            print(f"  y={cy}: die components={mm.count()} model runs={len(runs)}")
            for p in list(mm.each())[:6]:
                bb = p.bbox()
                print(f"    die x {bb.left}..{bb.right} ({(bb.right - bb.left) / 1000:.1f} um)")
            for x0, x1 in runs[:6]:
                print(f"    model x {x0}..{x1} ({(x1 - x0) / 1000:.1f} um)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
