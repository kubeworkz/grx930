#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""What a library cell draws on metal1/metal2, and what via cells the streamed die already has.

The stitch needs three numbers per cell: the metal1 rail rectangles (where a via1 may land), the
rail's y in the cell's own coordinates (so a placed copy can be projected), and the via cell names
the die already instantiates. This prints all three, plus a small window of the streamed die so the
metal2 occupancy that constrains a strap is read rather than assumed.

    python3 rail_and_via_geometry.py --lib <lib.gds> --gds <die.gds> [--window x0,y0,x1,y1]
"""

import argparse

import klayout.db as db

CELLS = ["clkinv_1", "nand2_1", "dffq_1", "mux2_1", "fill_1", "fill_4", "filltie"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True)
    ap.add_argument("--gds", required=True)
    ap.add_argument("--window", default="")
    args = ap.parse_args()

    lib = db.Layout()
    lib.read(args.lib)
    print(f"library {args.lib}: dbu={lib.dbu} cells={len(list(lib.each_cell()))}")

    for name in CELLS:
        cell = lib.cell(name) or lib.cell(f"gf180mcu_fd_sc_mcu7t5v0__{name}")
        if cell is None:
            print(f"-- {name}: not in library")
            continue
        box = cell.bbox(lib.layer(0, 0)) or cell.bbox()
        print(f"-- {cell.name} box={box} w={box.width()} h={box.height()}")
        for li in lib.layer_indexes():
            info = lib.get_info(li)
            if (info.layer, info.datatype) not in ((34, 0), (34, 10), (36, 0), (42, 0),
                                                   (21, 0), (35, 0), (38, 0)):
                continue
            shapes = cell.shapes(li)
            boxes = [s.box for s in shapes.each() if s.is_box()]
            texts = []
            for s in shapes.each():
                if s.is_text() and s.text is not None:
                    texts.append((s.text.string, s.text.trans.disp))
            if not boxes and not texts:
                continue
            print(f"   {info.layer}/{info.datatype}: {len(boxes)} boxes, {len(texts)} texts")
            for b in boxes[:10]:
                print(f"     box x {b.left}..{b.right} y {b.bottom}..{b.top} "
                      f"w={b.width()} h={b.height()}")
            if len(boxes) > 10:
                print(f"     ... {len(boxes) - 10} more")
            for t, p in texts[:6]:
                print(f"     text {t!r} at ({p.x},{p.y})")
            if len(texts) > 6:
                print(f"     ... {len(texts) - 6} more texts")

    ly = db.Layout()
    ly.read(args.gds)
    print(f"\ndie {args.gds}: dbu={ly.dbu} top={[c.name for c in ly.top_cells()]}")
    top = next(iter(ly.top_cells()))
    names = [c.name for c in ly.each_cell()]
    vias = sorted(n for n in names if n.upper().startswith("VIA"))
    print(f"cells={len(names)} via cells={len(vias)}: {vias[:12]}")
    for v in vias[:4]:
        vc = ly.cell(v)
        layers = []
        for li in ly.layer_indexes():
            info = ly.get_info(li)
            n = vc.shapes(li).size()
            if n:
                layers.append(f"{info.layer}/{info.datatype}x{n}")
        print(f"  {v}: box={vc.bbox()} {' '.join(layers)}")

    if args.window:
        x0, y0, x1, y1 = (int(v) for v in args.window.split(","))
        win = db.Box(x0, y0, x1, y1)
        print(f"\nwindow {win} (um {x0 * ly.dbu:.2f},{y0 * ly.dbu:.2f} .. "
              f"{x1 * ly.dbu:.2f},{y1 * ly.dbu:.2f})")
        for layer, label in (((34, 0), "metal1"), ((35, 0), "via1"), ((36, 0), "metal2"),
                             ((38, 0), "via2"), ((42, 0), "metal3"), ((21, 0), "nwell")):
            li = ly.layer(*layer)
            reg = db.Region(top.begin_shapes_rec(li)) & db.Region(win)
            if reg.is_empty():
                print(f"  {label:6s} none")
                continue
            bb = reg.bbox()
            print(f"  {label:6s} shapes={reg.count():5d} merged={reg.merged().count():5d} "
                  f"area={reg.area()} bbox={bb}")
            for p in list(reg.merged().each())[:6]:
                b = p.bbox()
                print(f"     x {b.left}..{b.right} y {b.bottom}..{b.top} "
                      f"w={b.width()} h={b.height()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
