#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Stream out the die the way the flow should have: DEF placements, library layouts, PDK numbers.

The artifact's problems, and what this does about each:

  * **cells are LEF abstracts** -> the 34 used cells come from the PDK library GDS (real
    transistors), and the abstracts are dropped;
  * **layer numbers are a LEF/DEF index scheme** (Metal1 = 5/0 ... Metal5 = 13/0, Pwell 1,
    Nwell 2) -> every shape is written with the PDK's numbers (metal1 34/0, via1 35/0, ...
    metal5 81/0, labels on *10);
  * **195 instances the design never places** (one of every unused library cell, `filltie`
    among them) -> placements come from the DEF's COMPONENTS instead of the artifact's instance
    list. A DEF position is the cell's *box* corner, so a mirrored/rotated copy has to be anchored
    at the opposite corner: `FS` one row up, `S` one row up and one width right, `FN` one width
    right. The artifact already does this (the offsets its author reported as defects are the
    anchors) and this script now reproduces them; placing every orientation at the raw DEF point
    put 30,097 of the 53,745 cells one row or column into a neighbour, which is the die's
    171,109-device extraction instead of 691,010 (doc/lvs_plan.md, 2026-11-02);
  * **no single top cell after a naive rebuild** -> only cells reachable from the top are kept.

Routing geometry comes from the DEF itself (`--routing def`, the default). The artifact's top
level is only its own die's wiring: 501,331 routed shapes and 644,699 vias written from a DEF
with 53,745 components. Copying them into a die with 125,210 placed cells would wire the
corrected design with the September netlist and put the wrong PDN under its rails -- which is
exactly what the first rebased stream did, and why `pdn_stitch` refused it.

The reader below is exact for every statement this DEF contains: `+ ROUTED`/`NEW` blocks with an
optional width and `+ SHAPE`, points (including `*` and the third "extension" integer OpenROAD
writes on five points), `RECT ( dx1 dy1 dx2 dy2 )` taken literally, and a via name as a
placement of that via's cell at the preceding point. A segment becomes a square-capped box --
OpenROAD's own rectangle for a wire -- so collinear runs join and a 90-degree corner overlaps by
half a width. A width the statement does not state comes from the LEF. Anything unreadable is
refused, never guessed at.

Via *geometry* still comes from the artifact: its seven `VIA_*` children are the writer's
rendering of the same LEF via definitions this DEF names, so they keep geometry that September's
691,010-device extraction already exercised. Their placements are the DEF's, not the artifact's.
`--routing artifact` reproduces the old behaviour, for re-checking the September die only.

    python3 tools/lvs_chip/stream_out.py [--routing def|artifact] [--lef FILE] [--out FILE]

Exit status: 0 written, 2 refused (an input missing, or a placement mismatch).
"""

import argparse
import re
import sys
from collections import Counter, defaultdict

ART = "/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"
LIB = "/work/c930/asic_gf180mcu/build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds"
LEF = "/work/c930/asic_gf180mcu/build/cells.lef"
DEF = "/work/c930/asic_gf180mcu/build/grx930_test_chip.def"
DEFAULT_OUT = "/work/c930/asic_gf180mcu/build/lvs_chip/stream_out.gds"

REMAP = {(5, 0): (34, 0), (5, 1): (34, 10), (6, 0): (35, 0), (7, 0): (36, 0), (7, 1): (36, 10),
         (8, 0): (38, 0), (9, 0): (42, 0), (9, 1): (42, 10), (10, 0): (40, 0), (11, 0): (46, 0),
         (11, 1): (46, 10), (12, 0): (41, 0), (13, 0): (81, 0), (13, 1): (81, 10)}
DROP_FROM_CELLS = {(1, 1), (1, 2), (2, 1), (2, 2), (5, 2), (5, 3), (7, 2), (9, 2), (11, 2),
                   (13, 2), (14, 0), (15, 0)}
# DEF orientation -> KLayout Trans. The integer is **quarter turns** (KLayout's `Trans(1, False)`
# is r90), and `mirror` is about the x axis, which is what the DEF's F* orientations mean:
# FN = mirror about Y = Trans(2, True), FS = mirror about X = Trans(0, True).
# Only N, S, FN and FS occur in this design's DEF; W/E/FW/FE are the standard rotations, kept so an
# eyeballed DEF does not silently fall through the table.
ORIENT = {"N": (0, False), "W": (1, False), "S": (2, False), "E": (3, False),
          "FN": (2, True), "FS": (0, True), "FW": (1, True), "FE": (3, True)}


def parse_def_units(path):
    """Distance units per micron from the DEF header (`UNITS DISTANCE MICRONS 2000`)."""
    for line in open(path, errors="replace"):
        m = re.match(r"UNITS\s+DISTANCE\s+MICRONS\s+(\d+)", line.strip())
        if m:
            return int(m.group(1))
        if line.strip().startswith("COMPONENTS"):
            break
    return 0


def parse_def_rows(path):
    """[(row name, y, orient, sites, step)] from ROW -- the DEF's own row grid.

    The placement gate used to infer the pitch from the components' own y values, which only works
    while every row carries a cell. A DEF with a filler pass still has empty rows, and the first
    two placed rows can then be two pitches apart, so the grid must come from the ROW statements.
    """
    rows = []
    for line in open(path, errors="replace"):
        m = re.match(r"ROW\s+(\S+)\s+(\S+)\s+(\d+)\s+(\d+)\s+(\w+)\s+DO\s+(\d+)\s+BY\s+1\s+STEP\s+(\d+)",
                     line.strip())
        if m:
            rows.append((m.group(1), int(m.group(4)), m.group(5), int(m.group(6)), int(m.group(7))))
        if line.strip().startswith("COMPONENTS"):
            break
    return rows


def parse_def_components(path):
    """[(inst, cell, x, y, orient)] from COMPONENTS."""
    comps = []
    section = None
    for line in open(path, errors="replace"):
        s = line.strip()
        if s.startswith("COMPONENTS"):
            section = "comp"
            continue
        if s.startswith("END COMPONENTS"):
            break
        if section != "comp":
            continue
        m = re.match(r"-\s+(\S+)\s+(\S+)\s+.*?\b(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)",
                     s)
        if m:
            comps.append((m.group(1), m.group(2), int(m.group(3)), int(m.group(4)), m.group(5)))
    return comps


# DEF routing layer -> the label layer the deck reads for that metal. The deck's own labels live on
# metal+10 (34/10 is metal1's text layer, see REMAP), and KLayout names a net from a text that sits
# on one of its shapes, so a label must be written on the same metal as the wire it names.
LABEL_LAYER = {"Metal1": (34, 10), "Metal2": (36, 10), "Metal3": (42, 10),
               "Metal4": (46, 10), "Metal5": (81, 10)}


def parse_def_net_labels(path):
    """[(name, layer, x, y)] -- one label per routed net, at the first point of its first wire.

    Why this exists: the comparer resolves ambiguous net matches from net names when it has them
    (`consider_net_names`, on by default, and KLayout's own reference calls labels "the preferred
    solution" over raising the branch complexity). The die carries 27 distinct metal1 labels for
    ~100k nets, so on this file the comparer is doing topology-only matching, which is the
    expensive path. The DEF already has every net's name; this is where they come from.

    The point chosen is the first vertex of the net's first `ROUTED` statement, which by
    construction lies on that net's wire. Coordinates are DEF distance units; the caller rescales.
    """
    labels = []
    net = None
    layer = None
    in_section = False
    want_point = False
    point_re = re.compile(r"\(\s*(\d+)\s+(\d+)\s*\)")
    for line in open(path, errors="replace"):
        s = line.strip()
        if s.startswith("NETS") or s.startswith("SPECIALNETS"):
            in_section = True
            net = layer = None
            continue
        if s.startswith("END NETS") or s.startswith("END SPECIALNETS"):
            in_section = False
            net = None
            continue
        if not in_section:
            continue
        if s.startswith("-"):
            net = s.split()[1]
            layer = None
            want_point = False
            continue
        if net is None:
            continue
        if "ROUTED" in s:
            rest = s.split("ROUTED", 1)[1].split()
            layer = LABEL_LAYER.get(rest[0]) if rest else None
            want_point = layer is not None
        if want_point:
            m = point_re.search(s)
            if m:
                labels.append((net, layer, int(m.group(1)), int(m.group(2))))
                net, layer = None, None
                want_point = False
    return labels


# DEF layer name -> the LEF/DEF layer index the artifact's shapes use. REMAP then gives the PDK
# number. Only the metals carry wires; the via cut layers are drawn by the via cells.
DEF_LAYER = {"Metal1": 5, "Via1": 6, "Metal2": 7, "Via2": 8, "Metal3": 9, "Via3": 10,
             "Metal4": 11, "Via4": 12, "Metal5": 13}
WIRE_LAYERS = ("Metal1", "Metal2", "Metal3", "Metal4", "Metal5")

# A routing point, with the optional third integer OpenROAD writes on five points of this DEF
# (`( 560 560 0 )`). It is an extension, always 0 here, and it is not geometry.
POINT_TOKEN = re.compile(r"\(\s*(\*|-?\d+)\s+(\*|-?\d+)(?:\s+(-?\d+))?\s*\)")
RECT_TOKEN = re.compile(r"RECT\s*\(\s*(-?\d+)\s+(-?\d+)\s*(-?\d+)\s*(-?\d+)\s*\)")
ROUTE_TOKEN = re.compile(r"RECT\s*\(\s*-?\d+\s+-?\d+\s+-?\d+\s+-?\d+\s*\)"
                         r"|\(\s*(?:\*|-?\d+)\s+(?:\*|-?\d+)(?:\s+-?\d+)?\s*\)"
                         r"|[A-Za-z_][0-9A-Za-z_]*")
ROUTE_STMT = re.compile(r"(ROUTED|NEW|FIXED|COVER|NOSHIELD)\s+([A-Za-z][0-9A-Za-z]*)")


def parse_def_die_area(path):
    """(x0, y0, x1, y1) from DIEAREA, in DEF distance units; None if absent."""
    for line in open(path, errors="replace"):
        s = line.strip()
        m = re.match(r"DIEAREA\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*"
                     r"\(\s*(-?\d+)\s+(-?\d+)\s*\)", s)
        if m:
            return tuple(int(v) for v in m.groups())
        if s.startswith("ROW "):
            break
    return None


def lef_layer_widths(path, units):
    """{Metal*: default wire width in DEF units} from the LEF's own LAYER blocks.

    A `NETS` segment states no width, so the drawn width is the layer's `WIDTH` (`Metal1 0.230`,
    `Metal2..4 0.280`, `Metal5 0.440`). The via layers also carry a `WIDTH 0.26` -- their cut
    size -- so they are skipped: a wire is never drawn on a cut layer.
    """
    widths = {}
    layer = None
    for line in open(path, errors="replace"):
        s = line.strip()
        m = re.match(r"LAYER\s+(\S+)", s)
        if m:
            layer = m.group(1)
            continue
        if layer and s == f"END {layer}":
            layer = None
            continue
        m = re.match(r"WIDTH\s+([\d.]+)", s)
        if m and layer in WIRE_LAYERS:
            widths.setdefault(layer, int(round(float(m.group(1)) * units)))
    return widths


def parse_def_routing(path, widths):
    """({layer: [(x0, y0, x1, y1)] boxes}, [(via, x, y)], Counter of what was read).

    Every routing statement is read exactly, in DEF distance units:

      * `( x y ) ( x y ) ...` -- consecutive points are segments; each becomes the square-capped
        box OpenROAD itself writes (`min(x) - w/2` .. `max(x) + w/2`), so a path joins at its
        vertices and a branch drawn from a point on another wire overlaps it by half a width;
      * `RE/* ... */CT ( dx1 dy1 dx2 dy2 )` -- a literal rectangle offset from its anchor point;
      * a via name -- a placement of that via's cell at the anchor point.

    `*` takes the coordinate of the previous point. Anything else -- an unknown token, a RECT with
    no single anchor, a width of zero on a wire, a layer with no LEF width -- is refused.
    """
    boxes = defaultdict(list)
    vias = []
    stats = Counter()
    section = None
    net = None
    layer = None
    width = None
    pts = []
    last = None

    def refuse(message):
        raise SystemExit(f"REFUSED  {message}")

    with open(path, errors="replace") as fh:
        for line in fh:
            s = line.strip()
            if s.startswith("NETS ") or s.startswith("SPECIALNETS "):
                section = "special" if s.startswith("SPECIAL") else "nets"
                net = layer = None
                pts, last = [], None
                continue
            if s.startswith("END NETS") or s.startswith("END SPECIALNETS"):
                section = None
                net = layer = None
                continue
            if section is None:
                continue
            if s.startswith("- "):
                net = s.split()[1]
                layer = None
                pts, last = [], None
                continue
            body = s[1:].strip() if s.startswith("+") else s
            m = ROUTE_STMT.match(body)
            if m:
                layer = m.group(2)
                rest = body[m.end():]
                width = None
                wm = re.match(r"\s*(\d+)\s*(.*)$", rest)
                if wm:
                    width = int(wm.group(1))
                    rest = wm.group(2)
                sm = re.match(r"\+\s*SHAPE\s+(\w+)\s*(.*)$", rest)
                if sm:
                    stats[f"shape_{sm.group(1)}"] += 1
                    rest = sm.group(2)
                pts, last = [], None
            elif layer is None:
                continue
            else:
                rest = body
            head = rest.partition(";")[0]
            pos = 0
            for t in ROUTE_TOKEN.finditer(head):
                gap = head[pos:t.start()]
                if gap.strip():
                    refuse(f"net {net} on {layer}: unreadable text {gap.strip()[:40]!r}")
                pos = t.end()
                tok = t.group(0)
                rm = RECT_TOKEN.match(tok)
                if rm:
                    if last is None or len(pts) != 1:
                        refuse(f"net {net} on {layer}: RECT without a single anchor point")
                    dx1, dy1, dx2, dy2 = (int(v) for v in rm.groups())
                    if dx2 <= dx1 or dy2 <= dy1:
                        refuse(f"net {net} on {layer}: RECT with no area")
                    boxes[layer].append((last[0] + dx1, last[1] + dy1,
                                         last[0] + dx2, last[1] + dy2))
                    stats["rect"] += 1
                    pts, last = [], None
                    continue
                if tok.startswith("("):
                    a, b, ext = POINT_TOKEN.match(tok).groups()
                    if a == "*" or b == "*":
                        if last is None:
                            refuse(f"net {net} on {layer}: `*` with no previous point")
                        x = last[0] if a == "*" else int(a)
                        y = last[1] if b == "*" else int(b)
                    else:
                        x, y = int(a), int(b)
                    if ext is not None:
                        stats["point_ext"] += 1
                    pts.append((x, y))
                    if len(pts) > 1:
                        x0, y0 = pts[-2]
                        w = width if width else widths.get(layer)
                        if not w or w % 2:
                            refuse(f"net {net} on {layer}: unusable wire width {w}")
                        h = w // 2
                        boxes[layer].append((min(x0, x) - h, min(y0, y) - h,
                                             max(x0, x) + h, max(y0, y) + h))
                        stats["segment"] += 1
                    last = (x, y)
                    continue
                if last is None:
                    refuse(f"net {net} on {layer}: via {tok} with no point")
                vias.append((tok, last[0], last[1]))
                stats["via"] += 1
                pts, last = [], None
            if head[pos:].strip():
                refuse(f"net {net} on {layer}: trailing text {head[pos:].strip()[:40]!r}")
    if not boxes or not vias:
        refuse(f"{path} yielded {sum(len(v) for v in boxes.values())} boxes and {len(vias)} vias")
    return boxes, vias, stats


def copy_shapes(src_layout, src_cell, dst_layout, dst_cell, keep_only_routing):
    moved = 0
    for li in src_layout.layer_indexes():
        info = src_layout.get_info(li)
        key = (info.layer, info.datatype)
        if key in DROP_FROM_CELLS:
            continue
        if keep_only_routing and key not in REMAP:
            continue
        target = REMAP.get(key)
        if target is None:
            continue
        shapes = dst_cell.shapes(dst_layout.layer(*target))
        for sh in src_cell.shapes(li).each():
            if sh.is_text():
                shapes.insert(sh.text)
            elif sh.is_box():
                shapes.insert(sh.box)
            elif sh.is_polygon():
                shapes.insert(sh.polygon)
            elif sh.is_path():
                shapes.insert(sh.path)
            moved += 1
    return moved


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", default=DEF,
                    help="DEF to stream (default: the routed die)")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--lef", default=LEF, help="LEF the DEF's layer widths and cell sizes come from")
    ap.add_argument("--routing", choices=("def", "artifact"), default="def",
                    help="stream the DEF's own NETS/SPECIALNETS (default) or the artifact's routing")
    args = ap.parse_args()
    def_path = args.def_file

    try:
        import klayout.db as db
    except ImportError:
        print("stream_out: CANNOT-RUN klayout.db is required")
        return 2

    def_units = parse_def_units(def_path)
    art = db.Layout()
    art.read(ART)
    art_top = art.cell("grx930_test_chip")
    # DEF coordinates are in distance units; the layout's are in dbu. Both are integers, so this
    # is an exact rescale -- and the placement match below only succeeds if it is the right one.
    if not def_units:
        print("REFUSED  no `UNITS DISTANCE MICRONS` in the DEF header")
        return 2
    scale = art.dbu * def_units
    print(f"units: DEF {def_units}/um, layout dbu {art.dbu} um, scale {scale:g}")

    comps = [(inst, cell, int(round(x / scale)), int(round(y / scale)), orient)
             for inst, cell, x, y, orient in parse_def_components(def_path)]
    print(f"DEF: {len(comps)} components over {len({c[1] for c in comps})} cell types")

    # The DEF is authoritative for where a cell goes; the artifact's own instance list is not,
    # because it is wrong for over half the design (see the comparison reported below). The gate
    # here is therefore internal: every placement must sit on the row grid and inside the die.
    unknown = sorted({c[4] for c in comps} - set(ORIENT))
    if unknown:
        print(f"REFUSED  unknown DEF orientations: {unknown}")
        return 2
    def_rows = parse_def_rows(def_path)
    if not def_rows:
        print("REFUSED  no ROW statements in the DEF, so the row grid is unknown")
        return 2
    row_grid = {int(round(r[1] / scale)) for r in def_rows}
    for inst, _cell, _x, y, _orient in comps:
        if y not in row_grid:
            print(f"REFUSED  {inst} at y={y} is not on a DEF ROW")
            return 2
    area = parse_def_die_area(def_path)
    if area is None:
        print("REFUSED  no DIEAREA in the DEF")
        return 2
    box = db.Box(int(round(area[0] / scale)), int(round(area[1] / scale)),
                 int(round(area[2] / scale)), int(round(area[3] / scale)))
    for inst, cell, x, y, _orient in comps:
        if not (box.left <= x <= box.right and box.bottom <= y <= box.top):
            print(f"REFUSED  {inst} at ({x},{y}) is outside the die {box}")
            return 2
    print(f"placements: {len(comps)} components, all on one of the {len(row_grid)} DEF rows "
          f"and inside the die {box} ({box.width() / 1000:g} x {box.height() / 1000:g} um)")

    # What the artifact did instead, orientation by orientation -- reported, never copied.
    artifact_pts = {}
    for inst in art_top.each_inst():
        if inst.cell.name.startswith("gf180mcu_fd_sc"):
            t = inst.trans
            artifact_pts.setdefault(inst.cell.name, set()).add((t.disp.x, t.disp.y))
    delta = {}
    for _inst, cell, x, y, orient in comps:
        best = min(artifact_pts.get(cell, {(x, y)}), key=lambda p: (abs(p[0] - x) + abs(p[1] - y), p))
        delta.setdefault(orient, Counter())[(best[0] - x, best[1] - y)] += 1
    for orient in sorted(delta):
        seen = delta[orient]
        total = sum(seen.values())
        exact = seen.get((0, 0), 0)
        print(f"  artifact {orient:2s}: {total:5d} components, {exact:5d} at the DEF position, "
              f"most common offset {seen.most_common(1)[0][0]} ({seen.most_common(1)[0][1]}x)")

    out = db.Layout()
    out.read(LIB)
    lib_cells = {c.name: c for c in out.each_cell()}

    top = out.create_cell("grx930_test_chip")
    via_count = 0
    via_xs, via_ys = [], []
    n_via_types = 0
    if args.routing == "def":
        widths = lef_layer_widths(args.lef, def_units)
        missing = [n for n in WIRE_LAYERS if n not in widths]
        if missing:
            print(f"REFUSED  {args.lef} states no WIDTH for {missing}")
            return 2
        print("layer widths: " + ", ".join(f"{n} {widths[n]}" for n in WIRE_LAYERS) + " DEF units")
        wires, vias, rstats = parse_def_routing(def_path, widths)
        print(f"routing: {sum(len(v) for v in wires.values())} wire boxes from "
              f"{rstats['segment']} segments and {rstats['rect']} RECTs, {len(vias)} vias "
              f"({rstats['point_ext']} points carried an extension)")

        # Via cells: the artifact names the writer's rendering of each LEF via `VIA_<name>`, and
        # this DEF uses exactly the seven names it has. Reuse that geometry; place it ourselves.
        art_vias = {i.cell.name: i.cell for i in art_top.each_inst()
                    if i.cell.name.startswith("VIA")}
        via_cells = {}
        for name in sorted({v[0] for v in vias}):
            source = art_vias.get(f"VIA_{name}")
            if source is None:
                print(f"REFUSED  the DEF uses via {name}, but the artifact has no VIA_{name}")
                return 2
            target = out.create_cell(f"VIA_{name}")
            if not copy_shapes(art, source, out, target, keep_only_routing=False):
                print(f"REFUSED  VIA_{name} copied no geometry")
                return 2
            via_cells[name] = target
        n_via_types = len(via_cells)

        layer_index = {}
        for name in WIRE_LAYERS:
            target = REMAP.get((DEF_LAYER[name], 0))
            if target is None:
                print(f"REFUSED  no PDK number for {name}")
                return 2
            layer_index[name] = out.layer(*target)
        for name, items in wires.items():
            shapes = top.shapes(layer_index[name])
            for x0, y0, x1, y1 in items:
                shapes.insert(db.Box(int(round(x0 / scale)), int(round(y0 / scale)),
                                     int(round(x1 / scale)), int(round(y1 / scale))))
        for name, x, y in vias:
            trans = db.Trans(int(round(x / scale)), int(round(y / scale)))
            top.insert(db.CellInstArray(via_cells[name].cell_index(), trans))
            via_count += 1
            via_xs.append(trans.disp.x)
            via_ys.append(trans.disp.y)
    else:
        moved = copy_shapes(art, art_top, out, top, keep_only_routing=True)
        print(f"top cell: {moved} routed shapes and labels moved to PDK numbers")

    # Net-name labels. Names are hints for the comparer, not connectivity: the deck extracts what
    # the geometry connects, and a label can only name a net the layout already has. The DEF's
    # names are sanitised exactly as mk_chip_cdl.py sanitises them, so the two sides agree.
    labels = parse_def_net_labels(def_path)
    written = 0
    for name, layer, x, y in labels:
        text = name.lstrip("\\").replace(" ", "")
        if not text:
            continue
        top.shapes(out.layer(*layer)).insert(
            db.Text(text, db.Trans(int(round(x / scale)), int(round(y / scale)))))
        written += 1
    print(f"net labels: {written} texts over {len({l for _n, l, _x, _y in labels})} label layers "
          f"({len({n for n, _l, _x, _y in labels})} distinct nets in the DEF)")

    if args.routing == "artifact":
        via_cells = {}
        for inst in art_top.each_inst():
            name = inst.cell.name
            if not name.startswith("VIA"):
                continue
            target = via_cells.get(name)
            if target is None:
                target = out.create_cell(name)
                copy_shapes(art, inst.cell, out, target, keep_only_routing=False)
                via_cells[name] = target
            # `CellInstArray(cell, dcplx_trans)` binds to the **integer** overload: the micrometre
            # numbers become database units, so a via at 1960.08 um lands at 1960 dbu = 1.96 um.
            # That is not a subtle shift -- it piles every via of the die into a 3 x 5 um corner,
            # and a pile of 132,753 coincident boxes is also what made `Region#merged()` look like
            # it could never finish (Claude outputs/stream_out_fix.md 4g). Convert through the
            # layout's dbu explicitly, and let the gate below refuse a file whose vias do not span
            # the die.
            trans = db.ICplxTrans(inst.dcplx_trans, out.dbu)
            top.insert(db.CellInstArray(target.cell_index(), trans))
            via_count += 1
            via_xs.append(trans.disp.x)
            via_ys.append(trans.disp.y)
        n_via_types = len(via_cells)
    print(f"vias: {via_count} placements, {n_via_types} via cell types, "
          f"span x {min(via_xs, default=0)}..{max(via_xs, default=0)} dbu, "
          f"y {min(via_ys, default=0)}..{max(via_ys, default=0)} dbu")
    if via_count:
        span_x = max(via_xs) - min(via_xs)
        span_y = max(via_ys) - min(via_ys)
        if span_x < box.width() // 2 or span_y < box.height() // 2:
            print(f"REFUSED  the via placements span {span_x} x {span_y} dbu, but the die is "
                  f"{box.width()} x {box.height()}: a unit error, not a design")
            return 2

    # The row box is the cell boundary layer, not the GDS bbox: the cells draw their wells 0.43 um
    # beyond the boundary so neighbouring wells merge, which makes the drawn bbox 0.86 um larger in
    # both axes. Anchoring on the bbox would open a gap at every cell edge.
    box_layer = out.find_layer(0, 0)
    if box_layer < 0:
        print("REFUSED  the library GDS has no layer 0/0 cell boundary, so the row box is unknown")
        return 2

    used = Counter()
    shifted = Counter()
    boxes = []
    sizes = {}
    for _inst, cell, x, y, orient in comps:
        target = lib_cells.get(cell)
        if target is None:
            print(f"REFUSED  {cell} is not in the library GDS")
            return 2
        size = sizes.get(cell)
        if size is None:
            sb = target.bbox(box_layer)
            if sb is None or sb.empty():
                print(f"REFUSED  {cell} has no layer 0/0 box in the library GDS")
                return 2
            size = sizes[cell] = (sb.width(), sb.height())
        w, h = size
        angle, mirror = ORIENT[orient]
        trans = db.Trans(angle, mirror)
        # Mirroring about the origin moves the w x h box to the lower-left of the DEF point for
        # FS/S/FN. Translate it back so the box lands on the row the DEF names.
        corners = [trans * db.Point(px, py) for px in (0, w) for py in (0, h)]
        trans.disp = db.Vector(x - min(p.x for p in corners), y - min(p.y for p in corners))
        if trans.disp != db.Vector(x, y):
            shifted[orient] += 1
        abs_box = trans * db.Box(0, 0, w, h)
        boxes.append((abs_box.bottom, abs_box.top, abs_box.left, abs_box.right, cell))
        top.insert(db.CellInstArray(target.cell_index(), trans))
        used[cell] += 1
    print(f"cells: {sum(used.values())} placed over {len(used)} types "
          f"(was {sum(1 for i in art_top.each_inst() if i.cell.name.startswith('gf180mcu_fd_sc'))}"
          f" in the artifact)")
    print(f"anchors: {sum(shifted.values())} of {len(comps)} copies moved off the raw DEF point"
          + "".join(f", {o} {n}" for o, n in sorted(shifted.items())))

    # The invariant the raw-anchor version broke: with every copy's box on its DEF row, no two boxes
    # overlap. Refuse rather than write a file that is silently a row off.
    rows = {}
    for y0, _y1, x0, x1, cell in boxes:
        rows.setdefault(y0, []).append((x0, x1, cell))
    for y0, items in rows.items():
        items.sort()
        for (a0, a1, ac), (b0, _b1, bc) in zip(items, items[1:]):
            if b0 < a1:
                print(f"REFUSED  {ac} and {bc} overlap in the row at y={y0} ({a1 - b0} dbu)")
                return 2
    extent = {}
    for y0, y1, _x0, _x1, _cell in boxes:
        extent[y0] = max(extent.get(y0, y1), y1)
    levels = sorted(extent.items())
    for (y0, y1), (ny0, _ny1) in zip(levels, levels[1:]):
        if ny0 < y1:
            print(f"REFUSED  the rows at y={y0} (to {y1}) and y={ny0} overlap")
            return 2

    # Keep only what the top needs: one reachable set, one top cell.
    reachable = set()
    stack = [top]
    while stack:
        cell = stack.pop()
        if cell.name in reachable:
            continue
        reachable.add(cell.name)
        for child in cell.each_child_cell():
            stack.append(out.cell(child))
    for index in [c.cell_index() for c in out.each_cell() if c.name not in reachable]:
        out.delete_cell(index)
    out.cleanup()
    if len(list(out.top_cells())) != 1:
        print(f"REFUSED  {len(list(out.top_cells()))} top cells after pruning")
        return 2

    present = {(info.layer, info.datatype) for info in out.layer_infos()}
    out.write(args.out)
    # `cells()` counts deleted slots too, so count what the file will actually contain.
    print(f"wrote {args.out}, {sum(1 for _ in out.each_cell())} cells, one top cell")
    for key in ((22, 0), (30, 0), (33, 0), (34, 0), (35, 0), (36, 0), (38, 0), (40, 0),
                (41, 0), (42, 0), (46, 0), (81, 0)):
        print(f"  layer {key}: {'present' if key in present else 'ABSENT'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
