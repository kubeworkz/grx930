#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Assemble a synthetic row (or grid) of one standard cell and write it as a layout.

Why: every placed cell extracts its own device count exactly (build/lvs_chip_cell_census.sh), and
every cell is 1:1 PFET:NFET, yet the assembled die returns 171,109 devices with a 1.94:1 PFET skew.
The two things an isolated cell does not have are neighbours and tiles. This builds the neighbour
case with nothing else changed: the same cell definition, placed `--count` times at its own bounding
box pitch, so the copies abut exactly as they do in a DEF row. `--gap-um` (or `--grid`) separates
"touching" from "merely near".

The layout has one top cell (`row_probe`) with one cell definition under it, so the deck reads the
same geometry N times and a count that is not N x the cell's own count is adjacency's doing.

Run in the flow image (klayout.db):
    python3 build/lvs_chip/probe/row_probe.py --gds build/lvs_chip/stream_out.gds \
        --cell gf180mcu_fd_sc_mcu7t5v0__mux2_1 --count 256 \
        --out build/lvs_chip/row_census/row_abut.gds
    python3 build/lvs_chip/probe/row_probe.py ... --gap-um 0.56 --out .../row_gap.gds
    python3 build/lvs_chip/probe/row_probe.py ... --grid 16x16 --out .../grid_abut.gds
"""

import argparse

import klayout.db as db


ORIENT = {"N": (0, False), "W": (1, False), "S": (2, False), "E": (3, False),
          "FN": (2, True), "FS": (0, True), "FW": (1, True), "FE": (3, True)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gds", required=True, help="layout that owns the cell definition")
    ap.add_argument("--cell", required=True)
    ap.add_argument("--count", type=int, default=256, help="placements in a one-dimensional row")
    ap.add_argument("--gap-um", type=float, default=0.0, help="extra space between copies")
    ap.add_argument("--pitch-x-um", type=float, default=None,
                    help="column pitch (default: the cell's bbox width); pass the LEF width to abut "
                         "the way the DEF places the cell, since the GDS bbox is wider than the LEF")
    ap.add_argument("--pitch-y-um", type=float, default=None,
                    help="row pitch (default: the cell's bbox height; the DEF row step is 3.92 um)")
    ap.add_argument("--grid", default=None, help="COLSxROWS instead of a row; abuts in both axes")
    ap.add_argument("--row-orients", default="N",
                    help="comma list of DEF orientations applied to successive rows (default N). "
                         "The DEF alternates N and FS by row, which is what lets neighbouring rows' "
                         "wells meet same-type; an all-N grid overlaps nwell with pwell.")
    ap.add_argument("--def-anchors", action="store_true",
                    help="keep each oriented copy inside its w x h row box, as a DEF placer means: "
                         "FS is anchored at the box top, S at the far corner, FN at the right edge. "
                         "Without this a KLayout Trans mirrors about the origin and the cell lands "
                         "one row/column low or left, overlapping its neighbour.")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    src = db.Layout()
    src.read(a.gds)
    cell = src.cell(a.cell)
    if cell is None:
        raise SystemExit(f"row_probe: no cell {a.cell} in {a.gds}")
    box = cell.bbox()
    w, h = box.width(), box.height()
    px = w if a.pitch_x_um is None else int(round(a.pitch_x_um / src.dbu))
    py = h if a.pitch_y_um is None else int(round(a.pitch_y_um / src.dbu))
    gap = int(round(a.gap_um / src.dbu))

    out = db.Layout()
    out.dbu = src.dbu
    dst = out.create_cell(a.cell)
    dst.copy_tree(cell)
    top = out.create_cell("row_probe")

    row_o = [ORIENT[o] for o in a.row_orients.split(",")]
    w_box, h_box = px, py

    def anchored(t, x, y):
        """Shift an oriented copy so its w_box x h_box box sits at (x, y), not its mirrored origin."""
        if a.def_anchors:
            if t.mirror and t.angle == 0:      # FS: mirror about x puts the box below the anchor
                y += h_box
            elif t.angle == 2 and t.mirror:    # FN: mirrored and rotated -> box to the left
                x += w_box
            elif t.angle == 2:                 # S: box below and left
                x += w_box
                y += h_box
        t.disp = db.Vector(x, y)
        return t

    if a.grid:
        cols, rows = (int(v) for v in a.grid.lower().split("x"))
        n = 0
        for r in range(rows):
            angle, mirror = row_o[r % len(row_o)]
            for c in range(cols):
                t = anchored(db.Trans(angle, mirror), c * (px + gap), r * (py + gap))
                top.insert(db.CellInstArray(dst.cell_index(), t))
                n += 1
        shape = f"grid {cols}x{rows}"
    else:
        for c in range(a.count):
            t = anchored(db.Trans(0, False), c * (px + gap), 0)
            top.insert(db.CellInstArray(dst.cell_index(), t))
        n = a.count
        shape = f"row of {a.count}"

    out.write(a.out)
    print(f"row_probe: {shape} of {a.cell.split('__')[-1]} at pitch "
          f"{px}x{py} dbu (+{gap}), cell bbox {w}x{h} dbu, wrote {a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
