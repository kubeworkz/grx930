# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Dump the metal1/via1 geometry of a window, shape by shape, from a streamed die.

    python3 window_dump.py --gds <die.gds> --x0 2199000 --x1 2211000 --y0 1536200 --y1 1537200
"""

import argparse

import klayout.db as db


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gds", required=True)
    ap.add_argument("--x0", type=int, required=True)
    ap.add_argument("--x1", type=int, required=True)
    ap.add_argument("--y0", type=int, required=True)
    ap.add_argument("--y1", type=int, required=True)
    ap.add_argument("--layers", default="34:0,35:0,36:0")
    args = ap.parse_args()

    ly = db.Layout()
    ly.read(args.gds)
    top = ly.top_cell()
    win = db.Box(args.x0, args.y0, args.x1, args.y1)
    print(f"{args.gds} dbu={ly.dbu} top={top.name}")
    for spec in args.layers.split(","):
        ln, dt = (int(v) for v in spec.split(":"))
        li = ly.find_layer(ln, dt)
        if li is None:
            continue
        reg = db.Region(top.begin_shapes_rec(li)) & db.Region(win)
        print(f"-- {ln}/{dt}: {reg.count()} shapes in the window")
        merged = reg.merged()
        print(f"   merged components: {merged.count()}")
        for p in sorted(merged.each(), key=lambda q: -q.area())[:12]:
            bb = p.bbox()
            print(f"   {bb}  w={bb.width()} h={bb.height()} area={p.area()}")


if __name__ == "__main__":
    main()
