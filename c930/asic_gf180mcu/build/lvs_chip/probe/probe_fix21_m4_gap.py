#!/usr/bin/env python3
"""Read-only: inspect the M4 gap between the paired A2 and _076858_ routes."""
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
WIN = db.Box(1_840_000, 1_470_000, 1_874_000, 1_492_000)


def reg(ly, top, num):
    li = ly.find_layer(db.LayerInfo(num, 0))
    if li is None:
        return db.Region()
    r = db.Region(top.begin_shapes_rec(li)) & db.Region(WIN)
    r.merge()
    return r


def bstr(b):
    return f"({b.left},{b.bottom};{b.right},{b.top})"


def main():
    t = time.time()
    ly = db.Layout()
    ly.read(TILE)
    top = ly.cell(TOP)
    print("READ", f"{time.time()-t:.1f}s", flush=True)
    for name, num in (("M4", 46), ("V4", 41), ("M5", 81), ("M3", 42), ("V3", 40)):
        r = reg(ly, top, num)
        print("REGION", name, num, "count", r.size(), "bbox", bstr(r.bbox()),
              flush=True)
        for i, p in enumerate(r.each()):
            print(f"  {name}[{i}] bbox={p.bbox()} area={p.area()}", flush=True)
    print("DONE", f"{time.time()-t:.1f}s", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.exit(1)
