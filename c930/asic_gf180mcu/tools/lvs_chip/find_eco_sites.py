#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Derive the Stage 5 ECO site list from the stitched GDS and the filled DEF.

Why this exists
---------------
The 2x2 drop list used to come from a KLayout L2N database (`/scripts/chip.l2n`): a netlist
extracted from the GDS and read back per net. That file is not in this tree and cannot be
regenerated from the artifacts that are here, so the finder asks the two sources that do exist:

  * `pre_eco.gds` -- the geometry the fill and stitch passes produced: the M1 islands, the M2
    routing the strap must keep away from and the `VSS` labels that mark the rows;
  * `filled.def` -- the database's own account of the power grid: the VSS/VDD M3 stripes and the
    `filltie` placements that are the substrate taps.

No `chip.l2n`, no L2N netlist, no per-net connectivity: an island is an M1 shape with a filltie
on it, a row is a VSS label row, and a strip is a DEF special-net stripe.

The DEF side is not text-parsed. `read_def_odb.py` runs under `openroad -python`, preflights
`import odb`, loads the LEF and DEF into OpenDB and hands back the VSS/VDD Metal3 stripe boxes
and filltie origins as JSON; this script spawns that reader (or reuses `--def-json`). KLayout is
used only for the GDS, which OpenDB cannot read.

The rules are the ones `validate_drop_windows_2x2.rb` applied, kept in micrometres here:

  * M2 strap 0.84 um with 0.28 um space each side => a 1.40 um keepout;
  * M1 landing 0.90 x 0.78 um, M3 landing 0.90 x 0.80 um;
  * the M2 strap extends 0.45 um past each via centre;
  * no VDD geometry inside the landing or the keepout.

Rows are the `VSS` label rows of the GDS; labels closer than 3 um are one row (the stitched GDS
is 1 nm/dbu, the old validator's 300 counted its 10 nm dbu). A site is legal when the M2 keepout
is empty over the whole strap, an M1 island is under the row point and a VSS M3 strip is under
the strap's other end. Rail-end sites are the ends of the long M1 VSS rails.

Output: `eco_sites.csv` (name, x, y, ty, kind) in GDS database units (1 nm), and a report with
`N_sub + N_rows + N_rail = N`. The DEF writer doubles these for its 2000 dbu/um frame; use
`to_def()`, never a second rounding.

    python3 tools/lvs_chip/find_eco_sites.py --gds pre_eco.gds --def filled.def \
        --out eco_sites.csv --report eco_sites.txt
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter

import klayout.db as db

# PDK numbers, the same ones stream_check.py names.
M1 = (34, 0)
M2 = (36, 0)
M3 = (42, 0)
M1_LABEL = (34, 10)

# The 2x2 rules, in micrometres (validate_drop_windows_2x2.rb: HALF/PAD_Y/M1_HALF/... in dbu of
# its 10 nm layout).
STRAP_HALF = 0.70           # 1.40 um keepout across the strap
PAD_Y = 0.45                # M2 extends 0.45 um past each via centre
M1_HALF, M1_V = 0.45, 0.39  # 0.90 x 0.78 landing
M3_HALF, M3_V = 0.45, 0.40  # 0.90 x 0.80 landing
ROW_GAP = 3.0               # labels closer than this are one row
X_STEP = 5.0                # candidate pitch along a row
STRIP_MIN_LEN = 100.0       # a stripe/rail must be at least this long
STRIP_MIN_H, STRIP_MAX_H = 1.0, 2.0
GRID_CELL = 10.0            # M2 / filltie bucket, as in the validator
EPS = 0.02                  # keepout is strict: no touching geometry


def nm(v):
    return int(round(v * 1000.0))


class BoxIndex:
    """Bucket rectangles into GRID_CELL squares so a window query is a handful of lookups."""

    def __init__(self, cell_um=GRID_CELL):
        self.cell = nm(cell_um)
        self.grid = {}

    def add(self, x0, y0, x1, y1):
        c = self.cell
        for kx in range(x0 // c, x1 // c + 1):
            for ky in range(y0 // c, y1 // c + 1):
                self.grid.setdefault((kx, ky), []).append((x0, y0, x1, y1))

    def hits(self, x0, y0, x1, y1):
        c = self.cell
        seen = set()
        for kx in range(x0 // c, x1 // c + 1):
            for ky in range(y0 // c, y1 // c + 1):
                for r in self.grid.get((kx, ky), ()):
                    if id(r) in seen:
                        continue
                    seen.add(id(r))
                    if r[0] <= x1 and x0 <= r[2] and r[1] <= y1 and y0 <= r[3]:
                        return True
        return False


def read_gds(path):
    layout = db.Layout()
    layout.read(path)
    top = layout.top_cell()
    if top is None:
        sys.exit(f"find_eco_sites: CANNOT-RUN {path} has no top cell")

    shapes = {}
    for name, (ln, dt) in (("m1", M1), ("m2", M2), ("m3", M3)):
        li = layout.find_layer(ln, dt)
        if li is None:
            if name == "m1":
                sys.exit(f"find_eco_sites: CANNOT-RUN {path} has no layer {ln}/{dt} ({name})")
            shapes[name] = []
            continue
        out = []
        it = top.begin_shapes_rec(li)
        while not it.at_end():
            b = it.shape().bbox()
            out.append((b.left, b.bottom, b.right, b.top))
            it.next()
        shapes[name] = out

    # Rows are the net labels drawn in the top cell, the same texts the old validator read; pin
    # labels inside the standard cells sit on every row and would merge them into one. Fall back
    # to recursive texts only when the top cell has none.
    labels = Counter()
    li = layout.find_layer(*M1_LABEL)
    if li is not None:
        for recursive in (False, True):
            if recursive:
                it = top.begin_shapes_rec(li)
                while not it.at_end():
                    shape = it.shape()
                    if shape.is_text() and shape.text.string.upper() == "VSS":
                        labels[shape.text.y] += 1
                    it.next()
            else:
                for shape in top.shapes(li):
                    if shape.is_text() and shape.text.string.upper() == "VSS":
                        labels[shape.text.y] += 1
            if labels:
                break
    return layout, shapes, labels


def vss_rows(label_ys):
    ys = sorted(label_ys)
    rows = []
    for y in ys:
        if not rows or y - rows[-1][-1] > nm(ROW_GAP):
            rows.append([])
        rows[-1].append(y)
    return [int(round(sum(r) / float(len(r)))) for r in rows]


def load_def_facts(args):
    """DEF-side facts through OpenDB, via `openroad -python` (or a JSON saved from one)."""
    if args.def_json:
        with open(args.def_json) as fh:
            facts = json.load(fh)
        facts["reader"] = "OpenDB (saved JSON)"
        facts["json"] = args.def_json
        return facts
    if not args.def_path:
        sys.exit("find_eco_sites: --def is required (or --def-json with saved facts)")
    if not args.lef:
        sys.exit("find_eco_sites: --lef is required when the DEF is read through OpenDB")
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "read_def_odb.py")
    openroad = args.openroad or shutil.which("openroad")
    if not openroad:
        sys.exit("find_eco_sites: CANNOT-RUN no openroad on PATH (needed for `openroad -python`)")
    fd, tmp = tempfile.mkstemp(prefix="find_eco_sites_def_", suffix=".json")
    os.close(fd)
    try:
        run = subprocess.run(
            [openroad, "-python", helper, "--lef", args.lef, "--def", args.def_path, "--out", tmp],
            capture_output=True, text=True)
        if run.returncode != 0:
            sys.stderr.write((run.stdout or "")[-2000:] + (run.stderr or "")[-4000:])
            sys.exit(f"find_eco_sites: OpenDB reader failed ({run.returncode})")
        with open(tmp) as fh:
            facts = json.load(fh)
        facts["openroad"] = openroad
        return facts
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main():
    ap = argparse.ArgumentParser(description="Stage 5 ECO site finder (GDS + DEF, no L2N).")
    ap.add_argument("--gds", required=True, help="stitched pre-ECO GDS")
    ap.add_argument("--def", dest="def_path", help="filled DEF (power grid, filltie)")
    ap.add_argument("--lef", help="LEF with the DEF's layers and masters (OpenDB reader)")
    ap.add_argument("--openroad", help="openroad binary (default: the one on PATH)")
    ap.add_argument("--def-json", help="reuse DEF facts written by read_def_odb.py")
    ap.add_argument("--out", required=True, help="eco_sites.csv")
    ap.add_argument("--report", required=True, help="report text")
    ap.add_argument("--progress", action="store_true", help="print row progress")
    args = ap.parse_args()

    t0 = time.time()
    layout, shapes, label_ys = read_gds(args.gds)
    print(f"PHASE read_gds {time.time()-t0:.0f}s shapes=" + str({k: len(v) for k, v in shapes.items()}), flush=True)
    m1, m2, m3 = shapes["m1"], shapes["m2"], shapes["m3"]
    rows = vss_rows(label_ys.keys())
    if not rows:
        sys.exit("find_eco_sites: CANNOT-RUN the GDS has no VSS labels to derive rows from")

    facts = load_def_facts(args)
    units = float(facts["def_units"])

    def def_nm(v):
        """DEF dbu -> GDS database units (nm), once, with the DEF's own scale."""
        return int(round(v * 1000.0 / units))

    def strips(boxes):
        out = []
        for x0, y0, x1, y1 in boxes:
            x0, y0, x1, y1 = def_nm(x0), def_nm(y0), def_nm(x1), def_nm(y1)
            if x1 - x0 >= nm(STRIP_MIN_LEN) and x1 - x0 >= y1 - y0:
                out.append((x0, x1, (y0 + y1) // 2))
        return out

    vss = strips(facts["vss_m3"])
    vdd = strips(facts["vdd_m3"])
    if not vss:
        sys.exit("find_eco_sites: CANNOT-RUN the DEF has no VSS Metal3 stripes")

    fillties = [(def_nm(x), def_nm(y)) for x, y in facts["fillties"]]
    ft_index = BoxIndex()
    for x, y in fillties:
        ft_index.add(x, y, x, y)

    # Islands: M1 shapes with a filltie point on them. No merge, no netlist: a tap is the anchor.
    t0 = time.time()
    islands = [b for b in m1 if fillties and ft_index.hits(b[0], b[1], b[2], b[3])]
    island_boxes = islands
    print(f"PHASE islands {time.time()-t0:.0f}s n={len(islands)}", flush=True)

    m2_index = BoxIndex()
    for b in m2:
        m2_index.add(*b)
    m3_index = BoxIndex()
    for b in m3:
        m3_index.add(*b)
    vdd_index = BoxIndex()
    vdd_boxes = []
    for x0, x1, y in vdd:
        box = (x0, y - nm(1.6) // 2, x1, y + nm(1.6) // 2)
        vdd_boxes.append(box)
        vdd_index.add(*box)
    vss_boxes = [(x0, y - nm(1.6) // 2, x1, y + nm(1.6) // 2) for x0, x1, y in vss]

    def keepout_free(x, y, ty):
        x0, x1 = x - nm(STRAP_HALF), x + nm(STRAP_HALF)
        y0 = min(y, ty) - nm(PAD_Y) - nm(EPS)
        y1 = max(y, ty) + nm(PAD_Y) + nm(EPS)
        return not (m2_index.hits(x0, y0, x1, y1) or vdd_index.hits(x0, y0, x1, y1))

    def covered_by_vss(x, ty):
        return any(b[0] <= x - nm(M3_HALF) and x + nm(M3_HALF) <= b[2]
                   and b[1] <= ty - nm(M3_V) and ty + nm(M3_V) <= b[3] for b in vss_boxes)

    def landings_ok(x, y, ty, anchor=None):
        """anchor=None means a tap island under the row; a rail box means the rail itself."""
        if not covered_by_vss(x, ty):
            return False
        m1_box = (x - nm(M1_HALF), y - nm(M1_V), x + nm(M1_HALF), y + nm(M1_V))
        boxes = island_boxes if anchor is None else [anchor]
        if not any(b[0] <= m1_box[0] and m1_box[2] <= b[2] and b[1] <= m1_box[1] and m1_box[3] <= b[3]
                   for b in boxes):
            return False
        m3_box = (x - nm(M3_HALF), ty - nm(M3_V), x + nm(M3_HALF), ty + nm(M3_V))
        if vdd_index.hits(*m3_box):
            return False
        return True

    rails = [b for b in m1
             if b[2] - b[0] >= nm(STRIP_MIN_LEN) and nm(STRIP_MIN_H) <= b[3] - b[1] <= nm(STRIP_MAX_H)]
    if len(rows) < 2 and rails:
        # Pin labels sit on every row of every cell and can merge into one band; the rails are the
        # row pitch then, one row per rail centre.
        rows = vss_rows(list(label_ys.keys()) + [(b[1] + b[3]) // 2 for b in rails])
        print(f"PHASE rows_with_rails={len(rows)}", flush=True)

    print(f"PHASE rows={len(rows)}", flush=True)
    t0 = time.time()
    sites = []
    row_fail = []
    for idx, y in enumerate(rows):
        ty = min(((b[1] + b[3]) // 2 for b in vss_boxes), key=lambda sy: abs(sy - y))
        if abs(ty - y) > nm(4.0):
            row_fail.append((y, idx, "no VSS strip within 4 um"))
            continue
        found = None
        for bx0, by0, bx1, by1 in islands:
            if by0 > y or by1 < y or bx1 - bx0 < 2 * nm(M1_HALF):
                continue
            x = bx0 + nm(M1_HALF)
            while x <= bx1 - nm(M1_HALF):
                if keepout_free(x, y, ty) and landings_ok(x, y, ty):
                    found = x
                    break
                x += nm(X_STEP)
            if found is not None:
                break
        if found is None:
            row_fail.append((y, idx, "no legal x in any sub island on the row"))
        else:
            sites.append((f"row_{idx:04d}", found, y, ty, "row"))
        if args.progress and (idx + 1) % 50 == 0:
            print(f"ROW_PROGRESS={idx + 1}/{len(rows)}", flush=True)

    # Rail ends: the two ends of each long M1 VSS rail, pulled in by half a landing. There is no
    # `$45264` name to look for any more; the rails are the same M1 geometry the stitch writes.
    rail_fail = 0
    for rail in rails:
        r0, r1, ry = rail[0], rail[2], (rail[1] + rail[3]) // 2
        ty = min(((b[1] + b[3]) // 2 for b in vss_boxes), key=lambda sy: abs(sy - ry))
        if abs(ty - ry) > nm(4.0):
            rail_fail += 1
            continue
        for end, sign in ((r0, 1), (r1, -1)):
            x = end + sign * nm(M1_HALF + EPS)
            if keepout_free(x, ry, ty) and landings_ok(x, ry, ty, anchor=rail):
                sites.append((f"rail_{len(sites):04d}", x, ry, ty, "rail"))
            else:
                rail_fail += 1

    print(f"PHASE rows_done {time.time()-t0:.0f}s sites={len(sites)}", flush=True)
    n_rows = sum(1 for s in sites if s[4] == "row")
    n_rail = sum(1 for s in sites if s[4] == "rail")
    n_sub = 0  # the filled DEF has no `sub` net; an island is only a tap-bearing M1 shape

    with open(args.out, "w") as fh:
        fh.write("# name,x,y,ty,kind -- GDS database units (1 nm)\n")
        for name, x, y, ty, kind in sites:
            fh.write(f"{name},{x},{y},{ty},{kind}\n")

    lines = [
        "ECO_SITE_FINDER",
        f"gds           {args.gds}",
        f"def           {args.def_path or facts.get('def', '?')}",
        f"lef           {args.lef or facts.get('lef', '?')}",
        f"def_reader    {facts['reader']}",
        f"openroad      {facts.get('openroad', 'in-process')}",
        f"odb_module    {facts.get('odb_module', '?')}",
        f"def_units     {facts['def_units']} dbu/um",
        f"dbu_um        {layout.dbu}",
        f"vss_labels    {sum(label_ys.values())}",
        f"vss_rows      {len(rows)}",
        f"vss_strips    {len(vss)}",
        f"vdd_strips    {len(vdd)}",
        f"fillties      {len(fillties)}",
        f"sub_islands   {len(islands)}",
        f"rail_shapes   {len(rails)}",
        f"N_sub         {n_sub}",
        f"N_rows        {n_rows}",
        f"N_rail        {n_rail}",
        f"N             {n_sub + n_rows + n_rail}",
        f"row_fail      {len(row_fail)}",
        f"rail_fail     {rail_fail}",
        "ECO_SITES: " + ("CLEAN" if sites else "EMPTY"),
    ]
    for y, idx, why in row_fail[:20]:
        lines.append(f"  ROW_FAIL idx={idx} y={y} {why}")
    open(args.report, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0 if sites else 1


if __name__ == "__main__":
    sys.exit(main())
