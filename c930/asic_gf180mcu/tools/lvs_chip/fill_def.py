#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Insert well taps and fillers into the routed DEF's empty row sites, metal1-aware.

Why this exists (doc/lvs_plan.md, 2026-11-02): the die's lvsdb carries 14,175 nets named VDD and
14,160 named VSS against one of each in the CDL, and its pfet bodies sit on 12,165 separate nwell
islands. The DEF explains both: it places no WELLTAP cell and no SPACER cell at all, so the metal1
rails stop at the last cell of every run (36,512 gaps, 324,729 um of them) and no tap binds an nwell
to a rail.

The first version of this pass tiled every empty site and shorted the supplies: 10,093 of its rails
landed on Metal1 NETS routing that used those sites, and the census put VDD and VSS on one
1.29 M-terminal net. The empty sites are empty of *cells*, not of *metal*. This version parses the
DEF's Metal1 routes (and via landing pads) and only fills where the rails are clear:

  * `fill_*` (CLASS SPACER) draws nothing but the two rails and the wells, so it needs both rail
    bands clear -- 98.6 % of the empty sites qualify;
  * `filltie` (CLASS WELLTAP) adds two vertical metal1 stubs inside its box, so it needs the whole
    box clear -- 52.5 % of the sites do;
  * a fill run must touch a cell edge, otherwise its rail would be an island with no device on it;
  * every placed filler is re-checked against the routes before the DEF is written, and the pass
    refuses rather than write a shorted file.

The second version read the DEF's Metal1 as points only, and padded every point as a via pad. That
is wrong for the 2,009 `( x y ) RECT ( dx1 dy1 dx2 dy2 )` shapes in this file, which are literal
rectangles whose width is routing, not a wire: 0.83 x 0.23 um against the 0.8 x 0.8 um the pad
model invented, starting 0.2 um to the right of the anchor instead of at it. Two fillers therefore
landed on the clock's own metal1 (doc/lvs_plan.md, 2026-11-03). Shapes are now read as statements --
`ROUTED`/`NEW` through the terminating `;`, across continuation lines -- and a RECT is taken
exactly, with a refusal for any statement whose syntax this pass does not model (`MASK`, `DO BY`,
a RECT inside a multi-point path, text after `;`). Conservative bounds are kept only where the DEF
really does not state the geometry: a via's metal1 pad is a `VIA_HALF` square and a wire centreline
is widened by `METAL1_HALF`.

What it does not do: `fillcap_*` cells are deliberately not used -- they contain MOS capacitors and
would change the device count that the census is measuring. `tiel`/`tieh` are not used either; they
have a driven output pin and nothing here needs a tie net. Empty rows are left empty: they carry no
cell, so a rail there would be a zero-terminal net and only inflate the net count.

    python3 tools/lvs_chip/fill_def.py [--def FILE] [--out FILE] [--tap-um 20]

Exit status: 0 written, 2 refused (a parse, placement, or short check failed).
"""

import argparse
import bisect
import re
import sys
from collections import Counter, defaultdict

DEF = "/work/c930/asic_gf180mcu/build/grx930_test_chip.def"
LEF = "/work/c930/asic_gf180mcu/build/cells.lef"
OUT = "/work/c930/asic_gf180mcu/build/lvs_chip/filled/grx930_test_chip_filled.def"

# Library cells this pass may place, by site count. Only SPACER and WELLTAP classes: neither
# contains a diffusion strip, so neither adds a device (checked on the library GDS: filltie has
# comp only as its two taps, fill_* has no comp or poly layer at all).
FILL = {64: "gf180mcu_fd_sc_mcu7t5v0__fill_64", 32: "gf180mcu_fd_sc_mcu7t5v0__fill_32",
        16: "gf180mcu_fd_sc_mcu7t5v0__fill_16", 8: "gf180mcu_fd_sc_mcu7t5v0__fill_8",
        4: "gf180mcu_fd_sc_mcu7t5v0__fill_4", 2: "gf180mcu_fd_sc_mcu7t5v0__fill_2",
        1: "gf180mcu_fd_sc_mcu7t5v0__fill_1"}
TIE = "gf180mcu_fd_sc_mcu7t5v0__filltie"
TIE_SITES = 2

ROW_RE = re.compile(r"^ROW\s+(\S+)\s+(\S+)\s+(\d+)\s+(\d+)\s+(\w+)\s+DO\s+(\d+)\s+BY\s+1\s+STEP\s+(\d+)")
COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\w+)")
POINT_RE = re.compile(r"\(\s*(\*|-?\d+)\s+(\*|-?\d+)\s*\)")
RECT_RE = re.compile(r"RECT\s*\(\s*(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s*\)")
STMT_RE = re.compile(r"(ROUTED|NEW|FIXED|COVER|NOSHIELD)\s+([A-Za-z][0-9A-Za-z]*)\s*")
# One routing token: a RECT, a point, or a via name. Anything else in a Metal1 statement is
# refused rather than guessed at.
TOKEN_RE = re.compile(r"RECT\s*\(\s*-?\d+\s+-?\d+\s+-?\d+\s+-?\d+\s*\)"
                      r"|\(\s*(?:\*|-?\d+)\s+(?:\*|-?\d+)\s*\)"
                      r"|[A-Za-z_][0-9A-Za-z_]*")
LAYERS = ("Metal1", "Metal2", "Metal3", "Metal4", "Metal5")

METAL1_HALF = 230     # 0.23 um route width / 2, in DEF units
RAIL_HALF = 600       # rails sit 0.3 um either side of a row edge
VIA_HALF = 400        # conservative metal1 landing pad for a via point


def refuse(message):
    print(f"REFUSED  {message}")
    return 2


def lef_sizes(path):
    """{macro: (width_um, height_um)} from the LEF, which is the DEF's own geometry source."""
    text = open(path, errors="replace").read()
    sizes = {}
    for m in re.finditer(r"^MACRO\s+(\S+)\n(.*?)^END\s+\1", text, re.S | re.M):
        s = re.search(r"^\s*SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", m.group(2), re.M)
        if s:
            sizes[m.group(1)] = (float(s.group(1)), float(s.group(2)))
    if not sizes:
        raise SystemExit(refuse(f"no MACRO/SIZE pairs in {path}"))
    return sizes


class ShapeSyntax(Exception):
    """A Metal1 routing statement whose geometry this pass cannot read exactly."""


class Metal1Shapes:
    """Exact Metal1 boxes from a net's routing lines, counting each shape kind in `stats` (a
    `collections.Counter`, so a missing key counts from zero).

    Three forms occur, and they are not interchangeable:

      * `( x y ) RECT ( dx1 dy1 dx2 dy2 )` -- a literal rectangle: the point plus the four offsets,
        exactly. This is the form the point-padding model got wrong;
      * `( x y ) Via1_HV|Via1_VV` -- a via, whose metal1 landing pad is `VIA_HALF` around the point;
      * `( x y ) ( x y ) ...` -- a wire centreline, widened by `METAL1_HALF`.

    DEF's grammar: `+ ROUTED <layer> ...` opens a routing block, each `NEW <layer> ...` line starts
    another wire in it, and the block ends at `;`. So a RECT -- which ends its own statement on this
    die -- must follow a single fresh anchor, while `*` may refer to any earlier point. Anything
    else is refused rather than guessed at.
    """

    def __init__(self, stats):
        self.stats = stats
        self.boxes = []
        self.pts = []
        self.last = None
        self.closed = False

    def new_wire(self):
        """A `ROUTED`/`NEW` line starts a new wire; `last` is kept so `*` still resolves."""
        self.pts = []
        self.closed = False

    def feed(self, text):
        pos = 0
        for m in TOKEN_RE.finditer(text):
            gap = text[pos:m.start()]
            if gap.strip():
                raise ShapeSyntax(f"unreadable text {gap.strip()[:40]!r} in {text[:60]!r}")
            pos = m.end()
            tok = m.group(0)
            rect = RECT_RE.match(tok)
            if rect:
                if self.last is None or len(self.pts) != 1:
                    raise ShapeSyntax(f"RECT with no single anchor in {text[:60]!r}")
                dx1, dy1, dx2, dy2 = (int(v) for v in rect.groups())
                box = (self.last[0] + dx1, self.last[1] + dy1,
                       self.last[0] + dx2, self.last[1] + dy2)
                if box[2] <= box[0] or box[3] <= box[1]:
                    raise ShapeSyntax(f"RECT with no area at {self.last} in {text[:60]!r}")
                self.boxes.append(box)
                self.stats["rect"] += 1
                self.pts = []
                self.closed = True
                continue
            if tok.startswith("("):
                if self.closed:
                    raise ShapeSyntax(f"point after a RECT or via in {text[:60]!r}")
                a, b = POINT_RE.match(tok).groups()
                if a == "*" and self.last is None:
                    raise ShapeSyntax(f"`*` with no previous point in {text[:60]!r}")
                x = self.last[0] if a == "*" else int(a)
                y = self.last[1] if b == "*" else int(b)
                if self.pts:
                    x0, y0 = self.pts[-1]
                    self.boxes.append((min(x0, x) - METAL1_HALF, min(y0, y) - METAL1_HALF,
                                       max(x0, x) + METAL1_HALF, max(y0, y) + METAL1_HALF))
                    self.stats["wire"] += 1
                self.pts.append((x, y))
                self.last = (x, y)
                continue
            if tok.lower().startswith("via"):
                if self.last is None:
                    raise ShapeSyntax(f"via with no point in {text[:60]!r}")
                self.boxes.append((self.last[0] - VIA_HALF, self.last[1] - VIA_HALF,
                                   self.last[0] + VIA_HALF, self.last[1] + VIA_HALF))
                self.stats["via"] += 1
                self.pts = []
                self.closed = True
                continue
            raise ShapeSyntax(f"unexpected token {tok!r} in {text[:60]!r}")
        if text[pos:].strip():
            raise ShapeSyntax(f"trailing text {text[pos:].strip()[:40]!r}")


def parse_def(path):
    """(units, rows, comps, metal1 boxes, shape counts).

    rows: (name, x0, y, orient, sites, step); comps: (inst, cell, x, y, orient);
    metal1: (x0, y0, x1, y1) boxes -- RECTs exactly, via pads as `VIA_HALF` squares, wire
    segments widened by `METAL1_HALF`.

    SPECIALNETS is not read: on this die it carries Metal3 to Metal5 only (169,390 Metal4 +
    66,677 Metal3 + 1,301 Metal5 shapes, no Metal1), so it cannot put metal under a filler's rails.

    Streamed: the DEF is 75 MB and the caller's container is small.
    """
    units = 0
    rows = []
    comps = []
    metal1 = []
    shapes = Counter()
    in_components = in_nets = False
    net = None
    layer = None        # the routing block's current layer, so other layers are skipped unparsed
    hold = Metal1Shapes(shapes)
    with open(path, errors="replace") as fh:
        for line in fh:
            s = line.strip()
            m = re.match(r"UNITS\s+DISTANCE\s+MICRONS\s+(\d+)", s)
            if m:
                units = int(m.group(1))
                continue
            m = ROW_RE.match(s)
            if m:
                rows.append((m.group(1), int(m.group(3)), int(m.group(4)), m.group(5),
                             int(m.group(6)), int(m.group(7))))
                continue
            if s.startswith("COMPONENTS"):
                in_components = True
                continue
            if s.startswith("END COMPONENTS"):
                in_components = False
                continue
            if in_components:
                m = COMP_RE.match(s)
                if m:
                    comps.append((m.group(1), m.group(2), int(m.group(3)), int(m.group(4)),
                                  m.group(5)))
                continue
            if s.startswith("NETS"):
                in_nets = True
                continue
            if s.startswith("END NETS"):
                in_nets = False
                continue
            if not in_nets:
                continue
            if s.startswith("- "):
                net = s.split()[1]
                layer = None
                hold.new_wire()
                continue
            # `+ ROUTED <layer> ...` opens a block, `NEW <layer> ...` is another wire in it (or a
            # block of its own), and `;` closes it. A line with no keyword continues the current
            # wire, so its points still form segments with the previous line's.
            body = s[1:].strip() if s.startswith("+") else s
            m = STMT_RE.match(body)
            if m:
                if m.group(2) not in LAYERS:
                    raise SystemExit(refuse(f"net {net}: unknown layer {m.group(2)!r}"))
                layer = m.group(2)
                hold.new_wire()
                rest = body[m.end():]
            elif layer is None:
                continue
            else:
                rest = body
            head, _, tail = rest.partition(";")
            if layer == "Metal1":
                try:
                    hold.feed(head)
                except ShapeSyntax as exc:
                    raise SystemExit(refuse(f"net {net}: {exc}"))
            if tail.strip():
                raise SystemExit(refuse(f"net {net}: text after `;`: {tail.strip()[:40]!r}"))
            if ";" in rest:
                layer = None
    if not units:
        raise SystemExit(refuse("no `UNITS DISTANCE MICRONS` in the DEF header"))
    if not rows:
        raise SystemExit(refuse("no ROW statements in the DEF"))
    if not comps:
        raise SystemExit(refuse("no components in the DEF"))
    metal1 = hold.boxes
    return units, rows, comps, metal1, shapes


class Routes:
    """Metal1 boxes bucketed by y so a site test touches a handful of them."""

    BIN = 1000

    def __init__(self, boxes):
        self.bands = defaultdict(list)
        for x0, y0, x1, y1 in boxes:
            for k in range(y0 // self.BIN, y1 // self.BIN + 1):
                self.bands[k].append((x0, y0, x1, y1))

    def hits(self, x0, y0, x1, y1):
        for k in range(y0 // self.BIN, y1 // self.BIN + 1):
            for sx0, sy0, sx1, sy1 in self.bands.get(k, ()):
                if sx0 < x1 and sx1 > x0 and sy0 < y1 and sy1 > y0:
                    return True
        return False


def write_def(src, dst, new):
    """Copy `src` to `dst`, keep the original components, and append `new` to their block."""
    kept = 0
    with open(src, errors="replace") as fi, open(dst, "w", newline="") as fo:
        in_components = False
        for line in fi:
            s = line.strip()
            if s.startswith("COMPONENTS"):
                fo.write(f"COMPONENTS {kept + len(new)} ;\n")
                in_components = True
                continue
            if in_components:
                if s.startswith("END COMPONENTS"):
                    for inst, cell, x, y, orient in new:
                        fo.write(f"    - {inst} {cell} + PLACED ( {x} {y} ) {orient} ;\n")
                    fo.write(line)
                    in_components = False
                    continue
                if COMP_RE.match(s):
                    kept += 1
                fo.write(line)
                continue
            fo.write(line)
    return kept


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", default=DEF)
    ap.add_argument("--lef", default=LEF)
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--tap-um", type=float, default=20.0,
                    help="DF.13_LV: max distance from an nwell tap to p-diffusion")
    args = ap.parse_args()

    units, rows, comps, metal1, shapes = parse_def(args.def_file)
    sizes = lef_sizes(args.lef)
    routes = Routes(metal1)

    step = rows[0][5]
    site_um = step / units
    for name, _x0, _y, _orient, _sites, row_step in rows:
        if row_step != step:
            return refuse(f"{name}: site step {row_step} differs from {step}")
    cell_h = int(round(sizes[_any_cell(comps)][1] * units))
    tap_units = int(round(args.tap_um * units))
    print(f"units: {units}/um, site {step} dbu = {site_um:.2f} um, row pitch "
          f"{rows[1][2] - rows[0][2] if len(rows) > 1 else 0} dbu, cell height {cell_h} dbu")
    print(f"rows: {len(rows)}, components: {len(comps)}, metal1 boxes: {len(metal1)}, "
          f"tap limit {args.tap_um:.2f} um")
    print(f"metal1 shapes: {shapes['rect']} RECT (exact), {shapes['wire']} wire segments, "
          f"{shapes['via']} via pads")

    row_by_y = {r[2]: r for r in rows}
    occupied = defaultdict(list)
    for inst, cell, x, y, _orient in comps:
        if y not in row_by_y:
            return refuse(f"{inst} at y={y} is not on a ROW")
        size = sizes.get(cell)
        if size is None:
            return refuse(f"{inst}: {cell} has no SIZE in the LEF")
        w = int(round(size[0] * units))
        row = row_by_y[y]
        if (x - row[1]) % row[5]:
            return refuse(f"{inst} at x={x} is off the {row[5]} dbu site grid of {row[0]}")
        if x < row[1] or x + w > row[1] + row[4] * row[5]:
            return refuse(f"{inst} at x={x} w={w} does not fit inside {row[0]}")
        occupied[y].append((x, x + w, inst))

    for sites, cell in sorted(FILL.items()):
        if int(round(sizes[cell][0] * units)) != sites * step:
            return refuse(f"{cell} is not {sites} sites wide")
    if int(round(sizes[TIE][0] * units)) != TIE_SITES * step:
        return refuse(f"{TIE} is not {TIE_SITES} sites wide")
    if abs(sizes[TIE][1] - sizes[FILL[1]][1]) > 1e-9:
        return refuse(f"{TIE} and {FILL[1]} differ in height")

    def rails_clear(x, y, w):
        return not (routes.hits(x, y - RAIL_HALF, x + w, y + RAIL_HALF) or
                    routes.hits(x, y + cell_h - RAIL_HALF, x + w, y + cell_h + RAIL_HALF))

    def box_clear(x, y, w):
        return not routes.hits(x, y, x + w, y + cell_h)

    new = []
    added = Counter()
    stats = Counter()
    ties = 0
    worst_cell = 0.0
    for name, x0, y, orient, sites, row_step in sorted(rows, key=lambda r: r[2]):
        used = sorted(occupied.get(y, []))
        if not used:
            continue
        row_end = x0 + sites * row_step
        tap_positions = []
        seq = 0
        last_tie = None
        for (a0, a1, _i0), (b0, _b1, _i1) in zip(used, used[1:]):
            if b0 <= a1:
                continue
            n = (b0 - a1) // row_step
            free = [rails_clear(a1 + i * row_step, y, row_step) for i in range(n)]
            # Maximal free runs that touch a cell edge; an interior run would be an island rail.
            runs = []
            i = 0
            while i < n:
                if not free[i]:
                    stats["blocked_sites"] += 1
                    i += 1
                    continue
                j = i
                while j < n and free[j]:
                    j += 1
                if i == 0 or j == n:
                    runs.append((i, j))
                else:
                    stats["island_runs"] += j - i
                i = j
            for i0, i1 in runs:
                i = i0
                while i < i1:
                    x = a1 + i * row_step
                    two = i + TIE_SITES <= i1
                    if two and box_clear(x, y, TIE_SITES * row_step) and \
                            (last_tie is None or x - last_tie >= tap_units):
                        new.append((f"FILL_{name}_{seq:05d}", TIE, x, y, orient))
                        tap_positions.append(x)
                        last_tie = x
                        ties += 1
                        added[TIE] += 1
                        seq += 1
                        i += TIE_SITES
                        continue
                    size = None
                    for s in sorted(FILL, reverse=True):
                        if i + s <= i1 and rails_clear(x, y, s * row_step):
                            size = s
                            break
                    if size is None:
                        return refuse(f"{name}: no filler fits at x={x} (run {i0}..{i1})")
                    new.append((f"FILL_{name}_{seq:05d}", FILL[size], x, y, orient))
                    added[FILL[size]] += 1
                    seq += 1
                    stats["filled_sites"] += size
                    i += size
        # Every cell must be within one tap limit of a tap. A row whose cells have no gap to a
        # tap-capable site cannot be fixed by a filler, so it is counted, not silently accepted.
        if tap_positions:
            for a0, a1, _i in used:
                k = bisect.bisect_left(tap_positions, a0)
                d = None
                if k < len(tap_positions):
                    d = max(0, tap_positions[k] - a1)
                if k > 0:
                    left = max(0, a0 - tap_positions[k - 1])
                    d = left if d is None else min(d, left)
                if d:
                    worst_cell = max(worst_cell, d / units)
        else:
            stats["rows_without_tap"] += 1

    if not new:
        return refuse("no fillable sites: is this DEF already filled?")

    # Re-check every placed cell against the routes before writing. The tiling used the same
    # predicate, so a hit here is a bug, not a coincidence.
    shorts = 0
    for inst, cell, x, y, _orient in new:
        w = int(round(sizes[cell][0] * units))
        if routes.hits(x, y - RAIL_HALF, x + w, y + RAIL_HALF) or \
                routes.hits(x, y + cell_h - RAIL_HALF, x + w, y + cell_h + RAIL_HALF):
            shorts += 1
            if shorts < 4:
                print(f"  SHORT? {inst} at ({x},{y})")
        if cell == TIE and not box_clear(x, y, w):
            shorts += 1
            if shorts < 4:
                print(f"  SHORT? {inst} tie stubs at ({x},{y})")
    if shorts:
        return refuse(f"{shorts} placed cells overlap metal1")

    kept = write_def(args.def_file, args.out, new)
    if kept != len(comps):
        return refuse(f"wrote {kept} original components, parsed {len(comps)}")

    print(f"placed {len(new)} filler cells: "
          + ", ".join(f"{c.replace('gf180mcu_fd_sc_mcu7t5v0__', '')}={n}"
                      for c, n in added.most_common()))
    print(f"sites filled={stats['filled_sites']} blocked-by-metal1={stats['blocked_sites']} "
          f"island-sites-left={stats['island_runs']}")
    print(f"well taps: {ties}, worst cell-to-tap {worst_cell:.2f} um "
          f"(limit {args.tap_um:.2f}), rows without a tap: {stats['rows_without_tap']}")
    print(f"rail/route overlaps after placement: 0 (checked {len(new)} cells)")
    print(f"wrote {args.out}: {len(comps) + len(new)} components "
          f"({len(comps)} placed + {len(new)} filler)")
    return 0


def _any_cell(comps):
    """A cell present in the DEF, to read the row height from the LEF."""
    return comps[0][1]


if __name__ == "__main__":
    sys.exit(main())
