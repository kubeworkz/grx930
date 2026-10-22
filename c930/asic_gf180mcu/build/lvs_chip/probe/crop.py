#!/usr/bin/env python3
"""crop.py -- clip the die to a square window. MEASURED NOT TO BE A TIMING PROXY; kept for what it
proved about `Layout#clip_into`.

WHAT IT DOES

  Writes a GDS with the die clipped to a square window, using KLayout's `Layout#clip_into`. The
  intent was to bracket the `align` wall (Claude outputs/stream_out_fix.md section 4c): the whole die
  sits in `align` for >45 min, so the idea was to run the same deck on 3 k, 11 k and 36 k placements
  and read the curve off the timings.

WHAT IT MEASURED INSTEAD

  `clip_into` into a fresh `Layout` copies the *cells*, not the top level:

    stream_out_crop400    std 3012  via      0  top shapes      0  layers 0
    stream_out_crop1600   std 35869 via      0  top shapes      0  layers 0
    stream_out             std 53745 via 644699  top shapes 501331  layers 27

  So the crops have no layer table, no top-level routing and none of the 644,699 `VIA_*` placements.
  Their comparison finishes in minutes (align 7.9 s at 3,012; 35.0 s at 11,047; 22.2 s at 35,869,
  all "Netlists don't match" as a clipped layout must), and those numbers say nothing about the
  die's align, because the netlist they align is cells-only. The timings are therefore **not**
  evidence of scaling; they are evidence that a clip made this way is not the die.

  Anyone wanting the real bracket has to clip the top level too -- copy the source layout, delete
  the placements outside the window and intersect the top-level shapes per layer -- and check
  `layers()` and the `VIA_` count before trusting the result.

  python build/lvs_chip/probe/crop.py --box-um 400 --out build/lvs_chip/stream_out_crop400.gds
"""
import argparse
import os
import sys

import klayout.db as db


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gds", default="build/lvs_chip/stream_out.gds")
    ap.add_argument("--out", default="build/lvs_chip/stream_out_crop.gds")
    ap.add_argument("--box-um", type=float, default=400.0,
                    help="side of the square window in micrometres (default 400)")
    ap.add_argument("--at-um", type=float, nargs=2, default=None,
                    help="lower-left corner of the window in micrometres "
                         "(default: die centre minus half the window)")
    args = ap.parse_args()

    src = db.Layout()
    src.read(args.gds)
    tops = [c for c in src.top_cells()]
    if len(tops) != 1:
        sys.exit(f"crop: CANNOT-RUN {len(tops)} top cells in {args.gds}; expected one")
    top = tops[0]

    die = top.dbbox()
    half = args.box_um / 2.0
    if args.at_um is None:
        mid = db.DPoint((die.left + die.right) / 2.0, (die.bottom + die.top) / 2.0)
        lo = db.DPoint(mid.x - half, mid.y - half)
    else:
        lo = db.DPoint(args.at_um[0], args.at_um[1])
    box = db.DBox(lo.x, lo.y, lo.x + args.box_um, lo.y + args.box_um)
    print(f"crop: die {die} um, window {box} um, top cell {top.name}")

    dst = db.Layout()
    dst.dbu = src.dbu
    new_top = src.clip_into(top, dst, box)
    dst.write(args.out)

    # Report what the crop lost, because that is the point: `layers()` and the VIA_ count are what
    # say whether this file is a crop of the die or only of its cells.
    via = sum(1 for ie in new_top.each_inst()
              if dst.cell(ie.cell_inst.cell_index).name.upper().startswith("VIA"))
    insts = sum(1 for _ in new_top.each_inst())
    cells = sum(1 for _ in dst.each_cell())
    top_shapes = sum(new_top.shapes(li).size() for li in range(dst.layers()))
    print(f"crop: wrote {args.out} ({os.path.getsize(args.out)} bytes), "
          f"{cells} cells, {insts} placements ({via} VIA_*), "
          f"{top_shapes} top shapes, {dst.layers()} layers under {new_top.name}")


if __name__ == "__main__":
    main()
