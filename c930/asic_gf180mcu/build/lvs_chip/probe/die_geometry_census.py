#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Count the die's device-defining shapes from the cell library and from the assembled layout.

Why: the die's extraction reports 171,109 devices where 53,745 placements x the cells' own device
counts is 691,010, and every cell extracts exactly on its own. Two things can produce that gap --
the assembled layout really carries less active geometry than the placements imply, or it carries
all of it and extraction loses devices. This counts, per cell type, the `comp` (active) polygons and
the `poly2` (gate) polygons in the cell definition, multiplies by the top cell's instance count, and
compares the sum with the die layout's own flattened layer count from the deck's log
(`comp has 167771 polygons`, `poly2 has 368897 polygons`, `nwell has 53745 polygons`).

A sum that matches the deck's count says the layout is fully populated and the loss is downstream of
geometry. A sum that is four times larger says the layout is missing three quarters of its cells'
geometry even though it places them.

Run in the flow image (klayout.db):
    python3 build/lvs_chip/probe/die_geometry_census.py \
        --gds build/lvs_chip/stream_out.gds --topcell grx930_test_chip
"""

import argparse
from collections import Counter

import klayout.db as db


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gds", required=True)
    ap.add_argument("--topcell", default="grx930_test_chip")
    ap.add_argument("--layers", default="22/0,30/0,21/0", help="comp,poly2,nwell layer/datatype")
    a = ap.parse_args()

    ly = db.Layout()
    ly.read(a.gds)
    top = ly.cell(a.topcell)
    if top is None:
        raise SystemExit(f"die_geometry_census: no top cell {a.topcell}")

    layer_keys = [tuple(int(x) for x in p.split("/")) for p in a.layers.split(",")]
    indexes = {k: ly.find_layer(k[0], k[1]) for k in layer_keys}

    placed = Counter()
    for inst in top.each_inst():
        placed[inst.cell.name] += 1

    totals = {k: 0 for k in layer_keys}
    print(f"{'cell':34s} {'places':>7s} " + " ".join(f"{k[0]}/{k[1]:<2d}" for k in layer_keys))
    for cell, n in placed.most_common():
        c = ly.cell(cell)
        counts = {}
        for k in layer_keys:
            li = indexes[k]
            counts[k] = 0 if li is None or li < 0 else int(c.shapes(li).size())
        for k in layer_keys:
            totals[k] += n * counts[k]
        print(f"{cell.split('__')[-1]:34s} {n:7d} " + " ".join(f"{counts[k]:5d}" for k in layer_keys))
    print(f"{'TOTAL':34s} {sum(placed.values()):7d} " + " ".join(f"{totals[k]:5d}" for k in layer_keys))
    print("die flattened (deck log): comp 167771, poly2 368897, nwell 53745")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
