#!/usr/bin/env python3
"""Read-only: locate A2 and _076858_ text labels in the fix20 tile."""
import os
import sys
import time
import traceback

import klayout.db as db

TILE = os.environ.get(
    "TILE",
    "/work/c930/asic_gf180mcu/build/lvs_chip/fix20_target_tile_y1398.gds",
)
TOP = "grx930_test_chip"
WANT = {"A2", "_076858_", "I0", "I1"}
WIN = db.Box(
    int(os.environ.get("X0", 1740000)),
    int(os.environ.get("Y0", 1460000)),
    int(os.environ.get("X1", 1790000)),
    int(os.environ.get("Y1", 1530000)),
)


def main():
    t = time.time()
    ly = db.Layout()
    ly.read(TILE)
    top = ly.cell(TOP)
    print("READ", f"{time.time()-t:.1f}s", "TOP", top.name, "BBOX", top.bbox(),
          flush=True)
    hits = 0
    for li in ly.layer_indexes():
        info = ly.get_info(li)
        if info.datatype != 10:
            continue
        it = top.begin_shapes_rec(li)
        while not it.at_end():
            sh = it.shape()
            if sh.is_text() and sh.text is not None and sh.text.string in WANT:
                tr = it.trans()
                disp = sh.text.trans.disp
                base = tr.trans(disp)
                d = tr.disp
                p = db.Point(base.x + d.x, base.y + d.y)
                b = sh.bbox()
                if WIN.contains(p):
                    print("LABEL", info.layer, info.datatype, repr(sh.text.string),
                          "xy", p.x, p.y, "box", b, "trans", tr, flush=True)
                    hits += 1
            it.next()
    print("HITS", hits, flush=True)
    print("DONE", f"{time.time()-t:.1f}s", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.exit(1)
