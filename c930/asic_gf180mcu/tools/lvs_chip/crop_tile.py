#!/usr/bin/env python3
"""crop_tile.py -- cut a window out of a flat layout, keeping the layer table and top-level shapes.

WHY

  The die's netlist phase does not return in 78 minutes (`Claude outputs/stream_out_fix.md` section
  4h), so merged-vs-unmerged can only be compared there as two horizons, not as two wall times. A
  window small enough for the netter to finish turns the same comparison into a ratio, and the
  window has to be a *real* crop of the die: same layers, same top-level routing, same via
  placements. `build/lvs_chip/probe/crop.py` is the counter-example worth not repeating -- it used
  `Layout#clip_into`, which copies cells and not the top level, so its crops had `layers() == 0`,
  no routing and none of the 644,699 vias, and every timing taken on them was meaningless.

WHAT IT DOES

  Reads a **flat** layout (one top cell, no instances -- which is what `merge_layers.py` writes, both
  merged and `--no-merge`), and for every layer intersects that layer's coverage with the window,
  writing the result into a single-cell layout with the same dbu, the same layer/datatype table and
  the same cell name (the deck is given `topcell=` and must find it). Texts whose anchor is inside
  the window are copied unchanged, because the deck reads pin names from them.

  The crop is *not* the die: wires crossing the window edge are cut, so the netter sees opens and the
  deck's verdict on a tile is expected to be a mismatch. What is being measured is the netlist phase,
  which does the same work on a cut net as on a whole one.

USAGE

  python3 tools/lvs_chip/crop_tile.py --gds build/lvs_chip/stream_out_merged.gds \\
      --out build/lvs_chip/tiles/tile1000_merged.gds --box-um 1000 \\
      --json build/lvs_chip/tiles/tile1000_merged.json
"""

import argparse
import json
import os
import sys
import time

import klayout.db as db


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gds", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--json", default=None)
    ap.add_argument("--box-um", type=float, nargs="+", default=[1000.0],
                    help="window size in micrometres: one number for a square, two for W H "
                         "(default 1000). A W x H window is how the full-height strip is cut -- "
                         "the strip keeps the vertical rails at their die length while the square "
                         "of the same area cuts both directions.")
    ap.add_argument("--at-um", type=float, nargs=2, default=None,
                    help="lower-left corner of the window in micrometres "
                         "(default: die centre minus half the window)")
    ap.add_argument("--no-texts", action="store_true",
                    help="drop labels; the window is then not the die's pin naming either")
    args = ap.parse_args()

    t0 = time.time()
    src = db.Layout()
    src.read(args.gds)
    tops = src.top_cells()
    if len(tops) != 1:
        sys.exit(f"crop_tile: {len(tops)} top cells in {args.gds}; expected one")
    top = tops[0]
    tops = None
    insts = sum(1 for _ in top.each_inst())
    if insts:
        sys.exit(f"crop_tile: {insts} instances under {top.name}; this crops flat layouts only, and "
                 f"a hierarchical crop is the clip_into trap (see the docstring)")
    print(f"read {args.gds} ({os.path.getsize(args.gds)} B) top={top.name} dbu={src.dbu} "
          f"{src.layers()} layers in {time.time() - t0:.1f} s", flush=True)

    die = top.dbbox()
    if len(args.box_um) == 1:
        win_w = win_h = args.box_um[0]
    elif len(args.box_um) == 2:
        win_w, win_h = args.box_um
    else:
        sys.exit("crop_tile: --box-um takes one side or W H")
    if args.at_um is None:
        lo_x = (die.left + die.right) / 2.0 - win_w / 2.0
        lo_y = (die.bottom + die.top) / 2.0 - win_h / 2.0
    else:
        lo_x, lo_y = args.at_um
    box_um = db.DBox(lo_x, lo_y, lo_x + win_w, lo_y + win_h)
    box = db.Box(round(box_um.left / src.dbu), round(box_um.bottom / src.dbu),
                 round(box_um.right / src.dbu), round(box_um.top / src.dbu))
    print(f"die {die} um; window {win_w} x {win_h} um = {box} dbu", flush=True)

    out = db.Layout()
    out.dbu = src.dbu
    otop = out.create_cell(top.name)
    keep = db.Region(box)

    rows = []
    texts_kept = 0
    texts_seen = 0
    for li in src.layer_indexes():
        info = src.get_info(li)
        oi = out.layer(info)
        t = time.time()
        reg = db.Region(top.begin_shapes_rec(li))
        before = reg.count()
        reg &= keep
        after = reg.count()
        for poly in reg.each():
            otop.shapes(oi).insert(poly)

        if not args.no_texts:
            ts = top.shapes(li)
            for shape in ts.each():
                if not shape.is_text():
                    continue
                texts_seen += 1
                disp = shape.text.trans.disp
                if box.contains(db.Point(disp.x, disp.y)):
                    otop.shapes(oi).insert(shape.text)
                    texts_kept += 1

        rows.append({"layer": f"{info.layer}/{info.datatype}", "before": before, "after": after,
                     "seconds": round(time.time() - t, 2)})
        print(f"  {info.layer:>3}/{info.datatype} {before:>9} -> {after:>8} "
              f"{time.time() - t:6.1f} s", flush=True)

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    out.write(args.out)

    total_before = sum(r["before"] for r in rows)
    total_after = sum(r["after"] for r in rows)
    record = {
        "input": args.gds,
        "output": args.out,
        "output_bytes": os.path.getsize(args.out),
        "top": top.name,
        "dbu": src.dbu,
        "window_um": [box_um.left, box_um.bottom, box_um.right, box_um.top],
        "window_dbu": [box.left, box.bottom, box.right, box.top],
        "die_um": [die.left, die.bottom, die.right, die.top],
        "polygons_before": total_before,
        "polygons_after": total_after,
        "layer_table_entries": out.layers(),
        "layers_with_shapes": sum(1 for r in rows if r["after"]),
        "texts_seen": texts_seen,
        "texts_kept": texts_kept,
        "seconds": round(time.time() - t0, 1),
        "layers": rows,
    }
    if args.json:
        os.makedirs(os.path.dirname(args.json) or ".", exist_ok=True)
        with open(args.json, "w") as fh:
            json.dump(record, fh, indent=2)
    print(f"crop_tile: {total_before} -> {total_after} polygons over "
          f"{record['layers_with_shapes']} layers, {texts_kept}/{texts_seen} texts, "
          f"{record['output_bytes']} B, {record['seconds']} s -> {args.out}")
    if not total_after:
        sys.exit("crop_tile: REFUSED -- the window has no shapes; that is not a tile of this die")


if __name__ == "__main__":
    main()
