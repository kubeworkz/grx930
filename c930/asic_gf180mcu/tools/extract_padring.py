#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Extract the pad-ring table and seal-ring inventory from a wafer.space layout.

Run inside the OpenLane 2 image (klayout bindings):

    MSYS_NO_PATHCONV=1 docker run --rm --user 0:0 \
      -v C:/Users/kubew/grx930/c930/asic_gf180mcu/tools:/data \
      --entrypoint /bin/sh ghcr.io/efabless/openlane2:2.3.10 \
      -c 'python3 /data/extract_padring.py /data/gf180mcu-example-layouts/5v/1x1/chip_top.oas'

GDS/OASIS do not carry instance names, so each pad is reported as
<cell> <x_um> <y_um> <orientation>; the *names* (clk_pad, inputs[i].pad, ...)
come from the project template RTL and its PAD_SOUTH/EAST/NORTH/WEST lists.

Optional second argument "frame" additionally reports which layers own
geometry in the outer 26 um seal-ring band (slow: walks every layer).
"""
import sys
from collections import Counter, defaultdict

try:
    import klayout.db as db
except ImportError:  # pragma: no cover
    import pya as db  # type: ignore

FRAME = 26.0  # seal-ring allowance on each side, from the wafer.space slot spec


def main(path):
    ly = db.Layout()
    ly.read(path)
    top = ly.top_cells()[0]
    bb = top.dbbox()
    print(f"FILE {path}")
    print(
        f"DBU {ly.dbu} TOP {top.name} "
        f"BBOX {bb.left:.3f} {bb.bottom:.3f} {bb.right:.3f} {bb.top:.3f}"
    )
    width, height = bb.width(), bb.height()

    pads, fills, wsip = [], Counter(), []
    for inst in top.each_inst():
        cell = inst.cell.name
        d = inst.trans.disp
        x, y = d.x * ly.dbu, d.y * ly.dbu
        if cell.startswith("gf180mcu_fd_io__"):
            if "fill" in cell:
                fills[cell] += 1
            else:
                pads.append((cell, x, y, str(inst.trans)))
        elif cell.startswith("gf180mcu_ws_ip__"):
            wsip.append((cell, x, y, str(inst.trans)))

    print(f"\nPAD_COUNT {len(pads)}")
    for cell, x, y, tr in sorted(pads, key=lambda p: (p[2], p[1])):
        print(f"PAD\t{cell}\t{x:.3f}\t{y:.3f}\t{tr}")

    print("\nPAD_CELLS (distinct)")
    for cell, n in Counter(p[0] for p in pads).most_common():
        print(f"  x{n:<3} {cell}")

    print("\nFILLERS")
    for cell, n in sorted(fills.items()):
        print(f"FILL {cell}\t{n}")

    print(f"\nWSIP_COUNT {len(wsip)}")
    for cell, x, y, tr in wsip:
        print(f"WSIP\t{cell}\t{x:.3f}\t{y:.3f}\t{tr}")

    # Group pads by which edge of the die their origin sits on.
    sides = defaultdict(list)
    for cell, x, y, tr in pads:
        if y < FRAME * 3:
            sides["S"].append((x, cell))
        elif y > height - FRAME * 3:
            sides["N"].append((x, cell))
        elif x < FRAME * 3:
            sides["W"].append((y, cell))
        else:
            sides["E"].append((y, cell))
    print("\nSIDES")
    for s in ("S", "E", "N", "W"):
        entries = sorted(sides[s])
        print(f"SIDE {s} count={len(entries)}")
        for axis, cell in entries:
            print(f"  {s} {axis:9.3f}  {cell}")

    print("\nSEAL_CELLS")
    for i in range(ly.cells()):
        c = ly.cell(i)
        if "seal" in c.name.lower() or "guard" in c.name.lower():
            cb = c.dbbox()
            print(
                f"SEAL {c.name}\t{cb.left:.3f}\t{cb.bottom:.3f}\t"
                f"{cb.right:.3f}\t{cb.top:.3f}"
            )

    if len(sys.argv) < 3 or sys.argv[2] != "frame":
        return

    # Which layers have geometry in the 26 um frame band? (Optional: this walks
    # every layer's shapes and can take minutes on a full chip layout.)
    m = int(FRAME / ly.dbu)
    w, h = int(width / ly.dbu), int(height / ly.dbu)
    frame_region = db.Region()
    frame_region.insert(db.Box(0, 0, w, m))
    frame_region.insert(db.Box(0, 0, m, h))
    frame_region.insert(db.Box(w - m, 0, w, h))
    frame_region.insert(db.Box(0, h - m, w, h))
    print("\nFRAME_LAYERS (shapes intersecting the outer 26 um band)")
    for li in ly.layer_infos():
        idx = ly.layer(li)
        reg = db.Region(top.begin_shapes_rec(idx))
        inter = reg.interacting(frame_region)
        n = inter.count()
        if n:
            print(f"  {li.name:<18} ({li.layer}/{li.datatype}): {n}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/data/chip_top.oas")
