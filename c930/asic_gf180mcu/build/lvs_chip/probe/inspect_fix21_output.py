#!/usr/bin/env python3
"""Read-only inspect the V4 instances and target hits in a fix21 GDS."""
import os
import sys

import klayout.db as db

GDS = os.environ.get(
    "GDS",
    "/work/c930/asic_gf180mcu/build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix21.gds",
)
TOP = "grx930_test_chip"
CELL = "VIA_via4_5_3200_6400_4_2_1240_1240"
TARGET = (1_843_800, 1_475_880)


def hit(top, ly, num, pt):
    li = ly.find_layer(db.LayerInfo(num, 0))
    r = db.Region(top.begin_shapes_rec(li)) & db.Region(
        db.Box(pt[0] - 5, pt[1] - 5, pt[0] + 5, pt[1] + 5))
    return r.count()


def main():
    ly = db.Layout()
    ly.read(GDS)
    top = ly.cell(TOP)
    print("GDS", GDS, "TOP", top.name, "INSTS", sum(1 for _ in top.each_inst()))
    print("TARGET_HITS", {n: hit(top, ly, n, TARGET) for n in (41, 46, 81)})
    for inst in top.each_inst():
        if inst.cell.name != CELL:
            continue
        d = inst.trans.disp
        print("V4INST", str(inst.trans), "disp", d.x, d.y,
              "bbox", db.Region(inst.cell.shapes(ly.find_layer(
                  db.LayerInfo(41, 0)))).bbox().transformed(inst.trans))
    return 0


if __name__ == "__main__":
    sys.exit(main())
