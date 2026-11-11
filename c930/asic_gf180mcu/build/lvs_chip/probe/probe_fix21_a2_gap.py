#!/usr/bin/env python3
"""Read-only: inspect the A2 M1 pin and the _076858_ M2 route at their gap."""
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
WIN = db.Box(1_762_000, 1_492_000, 1_769_000, 1_498_000)
A2 = db.Point(1_766_520, 1_494_920)
TARGET = db.Point(1_764_980, 1_494_920)


def reg(ly, top, num):
    li = ly.find_layer(db.LayerInfo(num, 0))
    if li is None:
        return db.Region()
    r = db.Region(top.begin_shapes_rec(li)) & db.Region(WIN)
    r.merge()
    return r


def bstr(b):
    return f"({b.left},{b.bottom};{b.right},{b.top})"


def comp_at(polys, pt):
    for i, p in enumerate(polys):
        if p.bbox().contains(pt) and p.inside(pt):
            return i
    return None


def nearest(polys, pt):
    rows = []
    for i, p in enumerate(polys):
        b = p.bbox()
        dx = max(b.left - pt.x, 0, pt.x - b.right)
        dy = max(b.bottom - pt.y, 0, pt.y - b.top)
        rows.append((dx * dx + dy * dy, i, b))
    return sorted(rows)[:8]


def main():
    t = time.time()
    ly = db.Layout()
    ly.read(TILE)
    top = ly.cell(TOP)
    print("READ", f"{time.time()-t:.1f}s", flush=True)
    regs = {name: reg(ly, top, num) for name, num in
            (("M1", 34), ("V1", 35), ("M2", 36), ("M3", 42))}
    for name, r in regs.items():
        print("REGION", name, r.size(), bstr(r.bbox()), flush=True)
    polys = {name: list(r.each()) for name, r in regs.items()}
    for name in polys:
        print("COMPONENTS", name, len(polys[name]), flush=True)
        for i, p in enumerate(polys[name]):
            print(f"  {name}[{i}] bbox={p.bbox()} area={p.area()}", flush=True)

    print("A2_POINT", A2.x, A2.y, flush=True)
    for name in ("M1", "M2", "M3"):
        i = comp_at(polys[name], A2)
        print("A2_COMP", name, i,
              bstr(polys[name][i].bbox()) if i is not None else None, flush=True)
        print("A2_NEAREST", name, flush=True)
        for d2, j, b in nearest(polys[name], A2):
            print(f"  {name}[{j}] d2={d2} bbox={b}", flush=True)

    print("TARGET_POINT", TARGET.x, TARGET.y, flush=True)
    for name in ("M1", "M2", "M3"):
        i = comp_at(polys[name], TARGET)
        print("TARGET_COMP", name, i,
              bstr(polys[name][i].bbox()) if i is not None else None, flush=True)

    print("VIA1_CENTERS", flush=True)
    for v in polys["V1"]:
        b = v.bbox()
        x = (b.left + b.right) // 2
        y = (b.bottom + b.top) // 2
        if WIN.contains(db.Point(x, y)):
            ia = comp_at(polys["M1"], db.Point(x, y))
            ib = comp_at(polys["M2"], db.Point(x, y))
            print(f"  V1 ({x},{y}) bbox={b} M1={ia} M2={ib}", flush=True)

    # Direct bbox gap between the A2 M1 component and the nearest M2 component.
    ia = comp_at(polys["M1"], A2)
    if ia is not None:
        b = polys["M1"][ia].bbox()
        print("A2_M1_BBOX", b, "right", b.right, flush=True)
        for d2, j, mb in nearest(polys["M2"], A2):
            gx = max(b.left - mb.right, mb.left - b.right, 0)
            gy = max(b.bottom - mb.top, mb.bottom - b.top, 0)
            print(f"GAP_TO_M2[{j}] d2={d2} bbox={mb} gx={gx} gy={gy}",
                  flush=True)
    print("DONE", f"{time.time()-t:.1f}s", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.exit(1)
