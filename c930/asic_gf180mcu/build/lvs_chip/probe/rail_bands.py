#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""For every cell the DEF places, the metal1 rail band its VDD and VSS texts sit on.

A library cell's supply rail is the metal1 polygon that carries its `VDD` / `VSS` text. The stitch
needs to know, per cell type, that band's exact box (so a via1 pad can be proven inside it) and
whether the band spans the cell's full width (so abutting copies really join). Refuses any cell
whose text is not on a full-width band: that would make the island map a guess.

    python3 rail_bands.py --lib <lib.gds> --def <filled.def>
"""

import argparse
import re

import klayout.db as db

ROW_HALF = 300  # rails are drawn 0.3 um either side of the row edge


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True)
    ap.add_argument("--def", dest="def_file", required=True)
    args = ap.parse_args()

    used = set()
    comp_re = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)")
    for line in open(args.def_file, errors="replace"):
        if line.startswith("COMPONENTS"):
            continue
        if line.startswith("END COMPONENTS"):
            break
        m = comp_re.match(line.strip())
        if m:
            used.add(m.group(2))
    print(f"DEF places {len(used)} cell types")

    lib = db.Layout()
    lib.read(args.lib)
    print(f"library {args.lib}: dbu={lib.dbu}")
    text_layer = lib.layer(34, 10)
    m1 = lib.layer(34, 0)
    box_layer = lib.layer(0, 0)

    bad = 0
    for name in sorted(used):
        cell = lib.cell(name)
        if cell is None:
            print(f"  {name}: MISSING")
            bad += 1
            continue
        box = cell.bbox(box_layer)
        if box is None or box.empty():
            print(f"  {name}: no 0/0 box")
            bad += 1
            continue
        w, h = box.width(), box.height()
        texts = {}
        for s in cell.shapes(text_layer).each():
            if s.is_text() and s.text is not None and s.text.string in ("VDD", "VSS"):
                texts[s.text.string] = s.text.trans.disp
        out = []
        for net in ("VDD", "VSS"):
            p = texts.get(net)
            if p is None:
                out.append(f"{net}=notext")
                bad += 1
                continue
            band_y = (0 if p.y <= h // 2 else h)
            band = db.Region(cell.begin_shapes_rec(m1)) & db.Region(
                db.Box(-10_000, band_y - ROW_HALF, w + 10_000, band_y + ROW_HALF))
            if band.is_empty():
                out.append(f"{net}=empty")
                bad += 1
                continue
            bb = band.bbox()
            full = bb.left <= 2 and bb.right >= w - 2
            exact = (bb.top - bb.bottom) == 2 * ROW_HALF
            out.append(f"{net} y{bb.bottom}..{bb.top} x{bb.left}..{bb.right}"
                       f"{'' if full else ' NOT-FULL'}{'' if exact else ' HEIGHT'}"
                       f" polys={band.merged().count()}")
            if not full or not exact:
                bad += 1
        print(f"  {name:44s} w={w:6d} h={h:5d}  " + "  ".join(out))
    print(f"cells with a non-full-width / non-standard rail: {bad}")
    raise SystemExit(0 if bad == 0 else 1)


if __name__ == "__main__":
    main()
