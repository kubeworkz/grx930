#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Derive the Stage 5 ECO site list from the stitched GDS and the filled DEF.

Why this exists
---------------
The 2x2 drop list used to come from a KLayout L2N database (`/scripts/chip.l2n`): a netlist
extracted from the GDS and read back per net. That file is not in this tree and cannot be
regenerated from the artifacts that are here, so the finder asks the two sources that do exist:

  * `pre_eco.gds` -- the geometry the fill and stitch passes produced: the M1 islands and the M2
    routing the strap must keep away from;
  * `filled.def` -- the database's own account of the power grid: the VSS/VDD M3 stripes and the
    `filltie` placements that are the substrate taps.

No `chip.l2n`, no L2N netlist, no per-net connectivity: an island is an M1 shape with a filltie
on it, a row is a VSS Metal3 stripe of the filled DEF, and a strip is a DEF special-net stripe.

The DEF side is not text-parsed. `read_def_odb.py` runs under `openroad -python`, preflights
`import odb`, loads the LEF and DEF into OpenDB and hands back the VSS/VDD Metal3 stripe boxes
and filltie origins as JSON; this script spawns that reader (or reuses `--def-json`). KLayout is
used only for the GDS, which OpenDB cannot read.

The rules are the ones `validate_drop_windows_2x2.rb` applied, kept in micrometres here:

  * M2 strap 0.84 um with 0.28 um space each side => a 1.40 um keepout;
  * M1 landing 0.90 x 0.78 um, M3 landing 0.90 x 0.80 um;
  * the M2 strap extends 0.45 um past each via centre;
  * no VDD geometry inside the landing or the keepout.

Rows are the VSS Metal3 stripes of the filled DEF: pdn draws one stripe per row band, so the
stripe centre is the row. The GDS `VSS` texts are counted in the report but are not the row
source -- in the stitched GDS they are cell-local pin labels (11 distinct y at the origin), not
top-level net labels, and every one of them would have to be paired with a stripe 460 um away.
The GDS is read through the cell hierarchy with each instance's transform applied; without it
every box is in its standard cell's local frame and nothing can ever match the DEF.

A site is legal when the M2 keepout is empty over the whole strap, an M1 island is under the row
point and a VSS M3 strip is under the strap's other end. The row point is the stripe centre when
an island there can hold the 0.90 x 0.78 landing; otherwise it moves onto the nearest island that
can, by at most half a standard-cell row -- the pitch is the site height of the DEF's own ROWS,
cross-checked against the filltie rows, and never more than half a stripe band, so the bound
follows the library instead of a number here. A stripe centre a few nanometres off a pad centre
would otherwise fail a test the pad itself can pass. Islands are indexed by y, so a row only visits
the islands that can reach it. Rail-end sites are the ends of the long M1 VSS rails.

The M1 landing is measured against the island's real polygons, not its bounding box: the tap-cell
M1 is a comb, so a pad can sit inside the box and still be mostly in one of its slots. A pad with
less than M1_MIN_COVER of its area on that metal is refused, and the overlap it did reach is
reported -- the bounding-box test alone accepted every site, whatever its slot happened to be.

A pad that would meet M1 outside its own island is refused outright: across a gap that shape is a
net the finder cannot identify, so the ECO's pad would short VSS to it. The report names the site
and the area it hit; nothing here asks the ECO to draw a bridge to unknown metal.

Output: `eco_sites.csv` (name, x, y, ty, kind, m1_cover) in GDS database units (1 nm), with the
pad's M1 overlap as a fraction, and a report with
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
X_STEP = 5.0                # candidate pitch along a row
STRIP_MIN_LEN = 100.0       # a stripe/rail must be at least this long
STRIP_MIN_H, STRIP_MAX_H = 1.0, 2.0
GRID_CELL = 10.0            # M2 / filltie bucket, as in the validator
EPS = 0.02                  # keepout is strict: no touching geometry
Y_BUCKET = 1.0              # island y-bucket: an M1 island is about a micrometre tall
M1_MIN_COVER = 0.50         # less than half the pad on the island's M1 is refused


def nm(v):
    return int(round(v * 1000.0))


def tap_gaps(ys):
    """Smallest and most common gap between adjacent filltie rows, in the caller's units."""
    rows = sorted(set(ys))
    gaps = [b - a for a, b in zip(rows, rows[1:]) if b > a]
    if not gaps:
        return 0, 0
    return min(gaps), Counter(gaps).most_common(1)[0][0]


def row_pitch(facts, tap_ys, to_nm):
    """One standard-cell row in nm, plus the line the report should show for where it came from.

    The DEF's ROWS are the authority: a placement row sits on a site, so the site height is the
    pitch. The taps are the cross-check, because the tap spacing alone cannot tell one row from
    two -- a DEF that taps only every other row has gaps of 2 rows and no smaller gap to reveal
    the one it skipped. Without ROWS the taps are all there is, and then an even spacing is
    refused for that reason rather than used: the bound would silently be two rows again.
    """
    heights = sorted({to_nm(h) for h in facts.get("row_heights", []) if h and h > 0})
    tap_min, tap_mode = tap_gaps(tap_ys)
    if heights:
        fits = [h for h in heights
                if not tap_mode or abs(tap_mode - int(round(tap_mode / float(h))) * h) <= 1]
        if len(fits) != 1:
            sys.exit("find_eco_sites: CANNOT-RUN the DEF's ROWS do not agree with its filltie rows "
                     f"(site heights {heights} nm, tap gaps min {tap_min} mode {tap_mode} nm)")
        if not tap_mode:
            return fits[0], "DEF ROWS site height (no filltie rows to check it)"
        every = int(round(tap_mode / float(fits[0])))
        return fits[0], f"DEF ROWS site height; fillties every {every} row(s)"
    if not tap_mode:
        sys.exit("find_eco_sites: CANNOT-RUN the DEF has no ROWS and no filltie rows")
    if tap_min < tap_mode:
        return tap_min, f"smallest filltie gap {tap_min} nm (DEF has no ROWS)"
    sys.exit("find_eco_sites: CANNOT-RUN the DEF has no ROWS and its fillties are evenly spaced "
             f"at {tap_mode} nm, which may be more than one row")


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


class YIndex:
    """Bucket boxes by their y extent so a row visits only the shapes that can reach it."""

    def __init__(self, cell_um=Y_BUCKET):
        self.cell = nm(cell_um)
        self.grid = {}

    def add(self, box):
        c = self.cell
        for ky in range(box[1] // c, box[3] // c + 1):
            self.grid.setdefault(ky, []).append(box)

    def span(self, y0, y1):
        """Every box whose y extent touches [y0, y1], each once."""
        c = self.cell
        seen = set()
        for ky in range(y0 // c, y1 // c + 1):
            for box in self.grid.get(ky, ()):
                if id(box) not in seen:
                    seen.add(id(box))
                    yield box


def read_gds(path):
    layout = db.Layout()
    layout.read(path)
    tops = layout.top_cells()
    if not tops:
        sys.exit(f"find_eco_sites: CANNOT-RUN {path} has no top cell")
    # A stream-out can leave the via masters as extra top cells. The die is the one with the
    # largest extent, and it is not always the first; sorting by area makes the pick deterministic.
    top = max(tops, key=lambda c: (c.bbox().area(), c.name))

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
            # The shapes live in the standard cells, the fill cells and the strap cells, not in the
            # top cell: `begin_shapes_rec` yields them in the child cell's frame, so the instance
            # transform has to be applied here or every box sits at the origin.
            t = it.trans()
            b = it.shape().bbox().transformed(t)
            out.append((b.left, b.bottom, b.right, b.top))
            it.next()
        shapes[name] = out

    # The VSS texts are cell-local pin labels; they are counted for the report only (rows come from
    # the DEF stripes). Same transform rule: an untransformed label lands wherever its cell is.
    labels = Counter()
    li = layout.find_layer(*M1_LABEL)
    if li is not None:
        it = top.begin_shapes_rec(li)
        while not it.at_end():
            shape = it.shape()
            if shape.is_text() and shape.text.string.upper() == "VSS":
                p = it.trans() * db.DPoint(shape.text.x, shape.text.y)
                labels[int(round(p.y))] += 1
            it.next()
    return layout, shapes, labels, top


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
    layout, shapes, label_ys, top = read_gds(args.gds)
    print(f"PHASE read_gds {time.time()-t0:.0f}s shapes=" + str({k: len(v) for k, v in shapes.items()}), flush=True)
    m1, m2, m3 = shapes["m1"], shapes["m2"], shapes["m3"]

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
    island_y = YIndex()
    for b in islands:
        island_y.add(b)
    print(f"PHASE islands {time.time()-t0:.0f}s n={len(islands)}", flush=True)

    rails = [b for b in m1
             if b[2] - b[0] >= nm(STRIP_MIN_LEN) and nm(STRIP_MIN_H) <= b[3] - b[1] <= nm(STRIP_MAX_H)]

    # The pad has to sit on metal, not merely inside the island's bounding box. Collect the real
    # polygons of the islands and rails once, keyed by the box that identifies them, so a pad is
    # measured against its own anchor and not against whatever metal happens to be nearby.
    t0 = time.time()
    wanted = {(b[0], b[1], b[2], b[3]) for b in islands + rails}
    anchor_polys = {}
    it = top.begin_shapes_rec(layout.find_layer(*M1))
    while not it.at_end():
        sh = it.shape()
        if not sh.is_text():
            tr = it.trans()
            bb = sh.bbox().transformed(tr)
            key = (bb.left, bb.bottom, bb.right, bb.top)
            if key in wanted:
                anchor_polys.setdefault(key, []).append(sh.polygon.transformed(tr))
        it.next()
    print(f"PHASE pad_metal {time.time()-t0:.0f}s shapes="
          f"{sum(len(v) for v in anchor_polys.values())}", flush=True)

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

    # One row per VSS stripe, and the row point is the stripe centre itself: pdn puts the stripe
    # under the row it feeds. (Rows are not the GDS labels; those are cell-local pin texts.)
    rows = [(y, y) for y in sorted({y for _, _, y in vss})]

    # How far a row point may move to sit on an island: half a row, so it reaches the row boundary
    # but never the next row, and never more than half the band of the stripe it drops to.
    pitch, pitch_src = row_pitch(facts, [y for _, y in fillties], def_nm)
    stripe_pitch = min((b[0] - a[0] for a, b in zip(rows, rows[1:])), default=0)
    snap = pitch // 2
    if stripe_pitch:
        snap = min(snap, stripe_pitch // 2)
    if snap <= 0:
        sys.exit("find_eco_sites: CANNOT-RUN the DEF's row pitch is not positive")

    def keepout_free(x, y, ty):
        x0, x1 = x - nm(STRAP_HALF), x + nm(STRAP_HALF)
        y0 = min(y, ty) - nm(PAD_Y) - nm(EPS)
        y1 = max(y, ty) + nm(PAD_Y) + nm(EPS)
        return not (m2_index.hits(x0, y0, x1, y1) or vdd_index.hits(x0, y0, x1, y1))

    def covered_by_vss(x, ty):
        return any(b[0] <= x - nm(M3_HALF) and x + nm(M3_HALF) <= b[2]
                   and b[1] <= ty - nm(M3_V) and ty + nm(M3_V) <= b[3] for b in vss_boxes)

    anchor_metal = {}

    def m1_cover(x, y, anchor):
        """Fraction of the 0.90 x 0.78 pad that is on the anchor's own M1 polygons.

        Nothing else is credited: a neighbouring island, or another net's metal under the pad,
        must not pay for this site's landing.
        """
        key = (anchor[0], anchor[1], anchor[2], anchor[3])
        metal = anchor_metal.get(key)
        if metal is None:
            metal = db.Region()
            for poly in anchor_polys.get(key, ()):
                metal.insert(poly)
            metal = metal.merged()
            anchor_metal[key] = metal
        pad = db.Region(db.Box(x - nm(M1_HALF), y - nm(M1_V), x + nm(M1_HALF), y + nm(M1_V)))
        return (pad & metal).area() / float(pad.area())

    def landings_ok(x, y, ty, anchor):
        """The M1 pad has to sit inside the anchor's extent, the M3 pad on the VSS stripe, and the
        M3 pad clear of VDD. How much of the M1 pad is on metal is measured separately."""
        if not covered_by_vss(x, ty):
            return False
        b = anchor
        m1_box = (x - nm(M1_HALF), y - nm(M1_V), x + nm(M1_HALF), y + nm(M1_V))
        if not (b[0] <= m1_box[0] and m1_box[2] <= b[2] and b[1] <= m1_box[1] and m1_box[3] <= b[3]):
            return False
        m3_box = (x - nm(M3_HALF), ty - nm(M3_V), x + nm(M3_HALF), ty + nm(M3_V))
        if vdd_index.hits(*m3_box):
            return False
        return True

    def row_islands(y):
        """The islands a row may drop onto, nearest row point first.

        An island is usable when its x extent holds a landing and its y extent holds one too; the
        row point is the stripe centre clamped into that y extent, so a pad whose centre is a
        nanometre off the stripe still matches. The clamp has to land inside the snap bound, not
        merely the island's box: a tall island can reach the window with its edge while its
        landing range sits past it. Sorting by the distance makes the site the closest legal one
        rather than whichever island the GDS happened to iterate first.
        """
        out = []
        for b in island_y.span(y - snap, y + snap):
            if b[2] - b[0] < 2 * nm(M1_HALF) or b[3] - b[1] < 2 * nm(M1_V):
                continue
            lo, hi = b[1] + nm(M1_V), b[3] - nm(M1_V)
            if lo > y + snap or hi < y - snap:
                continue
            ys = min(max(y, lo), hi)
            out.append((abs(ys - y), ys, b))
        out.sort(key=lambda t: (t[0], t[1], t[2][0], t[2][1]))
        return out

    print(f"PHASE rows={len(rows)}", flush=True)
    t0 = time.time()
    sites = []
    row_fail = []
    snapped = 0
    snap_max = 0
    low_cover = 0
    for idx, (y, ty) in enumerate(rows):
        found = None
        best_cover = 0.0
        tried = False
        for _, ys, b in row_islands(y):
            x = b[0] + nm(M1_HALF)
            while x <= b[2] - nm(M1_HALF):
                if keepout_free(x, ys, ty) and landings_ok(x, ys, ty, b):
                    tried = True
                    cov = m1_cover(x, ys, b)
                    best_cover = max(best_cover, cov)
                    if cov >= M1_MIN_COVER:
                        found = (x, ys, cov)
                        break
                x += nm(X_STEP)
            if found is not None:
                break
        if found is None:
            if tried:
                low_cover += 1
            row_fail.append((y, idx, best_cover, "cover" if tried else "no_island"))
        else:
            x, ys, cov = found
            if ys != y:
                snapped += 1
                snap_max = max(snap_max, abs(ys - y))
            sites.append((f"row_{idx:04d}", x, ys, ty, "row", cov, b))
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
            if keepout_free(x, ry, ty) and landings_ok(x, ry, ty, rail):
                cov = m1_cover(x, ry, rail)
                if cov >= M1_MIN_COVER:
                    sites.append((f"rail_{len(sites):04d}", x, ry, ty, "rail", cov, rail))
                else:
                    rail_fail += 1
            else:
                rail_fail += 1

    # A pad that touches M1 outside its own island would join VSS to whatever that shape is, and
    # the finder has no netlist to prove it is VSS too. Anything touching the anchor is already the
    # same conductor, so only a shape across a gap counts. Refuse those sites: a bridge would be a
    # new connection to a net nobody here has identified.
    t1 = time.time()
    pad_index = BoxIndex()
    for _, x, y, _, _, _, _ in sites:
        pad_index.add(x - nm(M1_HALF), y - nm(M1_V), x + nm(M1_HALF), y + nm(M1_V))
    near_pads = db.Region()
    if sites:
        it = top.begin_shapes_rec(layout.find_layer(*M1))
        while not it.at_end():
            sh = it.shape()
            if not sh.is_text():
                tr = it.trans()
                bb = sh.bbox().transformed(tr)
                if pad_index.hits(bb.left, bb.bottom, bb.right, bb.top):
                    near_pads.insert(sh.polygon.transformed(tr))
            it.next()
        near_pads = near_pads.merged()
    print(f"PHASE pad_foreign {time.time()-t1:.0f}s polys={near_pads.count()}", flush=True)

    kept, refused = [], []
    for s in sites:
        name, x, y, ty, kind, cov, anchor = s
        key = (anchor[0], anchor[1], anchor[2], anchor[3])
        pad = db.Region(db.Box(x - nm(M1_HALF), y - nm(M1_V), x + nm(M1_HALF), y + nm(M1_V)))
        comp = near_pads.interacting(anchor_metal[key])
        bad = (pad & (near_pads - comp)).area() / 1.0e6   # nm^2 -> um^2
        if bad:
            refused.append(s + (bad,))
        else:
            kept.append(s)
    sites = kept
    for name, x, y, ty, kind, cov, anchor, bad in refused:
        if kind == "row":
            idx = int(name.split("_")[1])
            row_fail.append((rows[idx][0], idx, cov, "foreign"))
    row_fail.sort(key=lambda f: f[1])
    print(f"PHASE rows_done {time.time()-t0:.0f}s sites={len(sites)} refused_foreign={len(refused)}", flush=True)
    n_rows = sum(1 for s in sites if s[4] == "row")
    n_rail = sum(1 for s in sites if s[4] == "rail")
    n_sub = 0  # the filled DEF has no `sub` net; an island is only a tap-bearing M1 shape
    covers = sorted(s[5] for s in sites)
    cover_min = covers[0] if covers else 0.0
    cover_med = covers[len(covers) // 2] if covers else 0.0
    thin = sum(1 for c in covers if c < 0.80)

    with open(args.out, "w") as fh:
        fh.write("# name,x,y,ty,kind,m1_cover -- GDS database units (1 nm), cover = pad area fraction\n")
        for name, x, y, ty, kind, cov, anchor in sites:
            fh.write(f"{name},{x},{y},{ty},{kind},{cov:.3f}\n")

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
        f"top_cell      {top.name}",
        f"vss_labels    {sum(label_ys.values())}",
        f"vss_rows      {len(rows)}",
        f"row_source    DEF VSS Metal3 stripes",
        f"row_pitch_um  {pitch / 1000.0:.3f} ({pitch_src})",
        f"stripe_pitch_um {stripe_pitch / 1000.0:.3f}",
        f"row_snap_um   {snap / 1000.0:.3f} (half a row, capped at half the stripe pitch)",
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
        f"row_fail_why  cover {low_cover} / no_island {sum(1 for f in row_fail if f[3] == 'no_island')}"
        f" / foreign {sum(1 for f in row_fail if f[3] == 'foreign')}",
        f"rows_snapped  {snapped} (max {snap_max} nm)",
        f"m1_min_cover  {M1_MIN_COVER:.3f} (pad area on the island's M1 polygons)",
        f"m1_cover_min  {cover_min:.3f}",
        f"m1_cover_med  {cover_med:.3f}",
        f"m1_cover_thin {thin} (< 0.80)",
        f"m1_foreign_sites {len(refused)} (M1 outside the anchor under the pad; refused)",
        f"rows_low_cover {low_cover}",
        f"rail_fail     {rail_fail}",
        "ECO_SITES: " + ("CLEAN" if sites else "EMPTY"),
    ]
    # Every refused row, not a sample: an unnamed row is one nobody can go and fix.
    for y, idx, cov, reason in row_fail:
        lines.append(f"  ROW_FAIL idx={idx} y={y} best_cover={cov:.3f} reason={reason}")
    for name, x, y, ty, kind, cov, anchor, bad in refused:
        lines.append(f"  PAD_FOREIGN {name} x={x} y={y} cover={cov:.3f} foreign_um2={bad:.3f}")
    open(args.report, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0 if sites else 1


if __name__ == "__main__":
    sys.exit(main())
