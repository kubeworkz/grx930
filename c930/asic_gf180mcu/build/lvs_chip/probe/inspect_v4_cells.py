#!/usr/bin/env python3
"""Read-only: inspect V4 cell variants and cut centers."""
import os
import sys

import klayout.db as db

GDS = os.environ.get(
    "GDS",
    "/work/c930/asic_gf180mcu/build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix21.gds",
)
TOP = "grx930_test_chip"
TARGET = db.Point(1_843_800, 1_475_880)
EXISTING = db.Point(1_870_010, 1_475_880)
V4 = db.LayerInfo(41, 0)


def main():
    ly = db.Layout()
    ly.read(GDS)
    top = ly.cell(TOP)
    li = ly.find_layer(V4)
    print("GDS", GDS, "TOP", top.name, "V4_LAYER", li)
    names = sorted({c.name for c in ly.each_cell() if c.name.startswith("VIA_via4_")})
    print("V4_CELLS", len(names), flush=True)
    for name in names:
        cell = ly.cell(name)
        r = db.Region(cell.shapes(li))
        print("CELL", name, "cuts", r.size(), "bbox", r.bbox(), flush=True)
        for p in list(r.each())[:12]:
            b = p.bbox()
            print("  CUT", b, "center", (b.left + b.right) // 2,
                  (b.bottom + b.top) // 2, flush=True)

    for label, pt in (("TARGET", TARGET), ("EXISTING", EXISTING)):
        print(label, pt.x, pt.y, flush=True)
        for inst in top.each_inst():
            if not inst.cell.name.startswith("VIA_via4_"):
                continue
            r = db.Region(inst.cell.shapes(li))
            for p in r.each():
                b = p.bbox().transformed(inst.trans)
                c = db.Point((b.left + b.right) // 2, (b.bottom + b.top) // 2)
                if abs(c.x - pt.x) <= 2000 and abs(c.y - pt.y) <= 2000:
                    print("  HIT", inst.cell.name, inst.trans, "cut", b,
                          "center", c.x, c.y, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
