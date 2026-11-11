#!/usr/bin/env python3
"""Read-only: find V4 via cells near the A2 / _076858_ M4-M5 crossing."""
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
TARGET = db.Point(1_843_800, 1_475_880)
EXISTING = db.Point(1_870_010, 1_475_880)


def main():
    t = time.time()
    ly = db.Layout()
    ly.read(TILE)
    top = ly.cell(TOP)
    v4 = ly.find_layer(db.LayerInfo(41, 0))
    m4 = ly.find_layer(db.LayerInfo(46, 0))
    m5 = ly.find_layer(db.LayerInfo(81, 0))
    print("READ", f"{time.time()-t:.1f}s", "V4", v4, "M4", m4, "M5", m5,
          flush=True)
    for name, li in (("M4", m4), ("M5", m5), ("V4", v4)):
        reg = db.Region(top.begin_shapes_rec(li)) & db.Region(WIN)
        reg.merge()
        print("REGION", name, "components", reg.size(), "bbox", reg.bbox(),
              flush=True)
        for p in reg.each():
            print("  ", name, p.bbox(), flush=True)

    cells = {}
    for inst in top.each_inst():
        sh = inst.cell.shapes(v4)
        if sh.size() == 0:
            continue
        b = db.Region(sh).bbox().transformed(inst.trans)
        if not b.overlaps(WIN):
            continue
        key = inst.cell.name
        cells.setdefault(key, []).append((inst.trans.disp, b, str(inst.trans)))
    print("V4_CELLS", sorted(cells), flush=True)
    for name, rows in sorted(cells.items()):
        print("CELL", name, "count", len(rows), flush=True)
        for d, b, tr in rows:
            print("  INST", tr, "disp", d, "v4bbox", b, flush=True)

    for label, pt in (("TARGET", TARGET), ("EXISTING", EXISTING)):
        print(label, pt.x, pt.y, flush=True)
        for name, li in (("M4", m4), ("M5", m5), ("V4", v4)):
            reg = db.Region(top.begin_shapes_rec(li))
            hit = (reg & db.Region(db.Box(pt.x - 5, pt.y - 5, pt.x + 5, pt.y + 5)))
            print("  HIT", name, hit.count(), flush=True)

    print("DONE", f"{time.time()-t:.1f}s", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.exit(1)
