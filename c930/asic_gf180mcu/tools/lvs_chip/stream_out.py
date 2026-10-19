#!/usr/bin/env python3
"""Stream out the die the way the flow should have: DEF placements, library layouts, PDK numbers.

The artifact's problems, and what this does about each:

  * **cells are LEF abstracts** -> the 34 used cells come from the PDK library GDS (real
    transistors), and the abstracts are dropped;
  * **layer numbers are a LEF/DEF index scheme** (Metal1 = 5/0 ... Metal5 = 13/0, Pwell 1,
    Nwell 2) -> every shape is written with the PDK's numbers (metal1 34/0, via1 35/0, ...
    metal5 81/0, labels on *10);
  * **195 instances the design never places** (one of every unused library cell, `filltie`
    among them) -> placements come from the DEF's COMPONENTS instead of the artifact's instance
    list, and the artifact's own placements are reported orientation by orientation: they are
    exact for N, one row high for FS, and somewhere else for FN and S;
  * **no single top cell after a naive rebuild** -> only cells reachable from the top are kept.

Routing geometry and the via cells come from the artifact itself: it is the writer's own output
for the DEF's NETS and SPECIALNETS, and rewriting wire widths from scratch would trade a known
file for an unknown one. `tools/lvs_chip/stream_check.py --routing-compare` then proves that
nothing but the cells and the numbers changed.

    python3 tools/lvs_chip/stream_out.py [--out FILE]

Exit status: 0 written, 2 refused (an input missing, or a placement mismatch).
"""

import argparse
import re
import sys
from collections import Counter

ART = "/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"
LIB = "/work/c930/asic_gf180mcu/build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds"
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
        m = re.match(r"-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)",
                     s)
        if m:
            comps.append((m.group(1), m.group(2), int(m.group(3)), int(m.group(4)), m.group(5)))
    return comps


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
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    try:
        import klayout.db as db
    except ImportError:
        print("stream_out: CANNOT-RUN klayout.db is required")
        return 2

    def_units = parse_def_units(DEF)
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
             for inst, cell, x, y, orient in parse_def_components(DEF)]
    print(f"DEF: {len(comps)} components over {len({c[1] for c in comps})} cell types")

    # The DEF is authoritative for where a cell goes; the artifact's own instance list is not,
    # because it is wrong for over half the design (see the comparison reported below). The gate
    # here is therefore internal: every placement must sit on the row grid and inside the die.
    unknown = sorted({c[4] for c in comps} - set(ORIENT))
    if unknown:
        print(f"REFUSED  unknown DEF orientations: {unknown}")
        return 2
    ys = sorted({c[3] for c in comps})
    row = ys[1] - ys[0]
    for _inst, _cell, _x, y, _orient in comps:
        if y % row:
            print(f"REFUSED  component at y={y} is off the {row} dbu row grid")
            return 2
    box = art_top.bbox()
    for inst, cell, x, y, _orient in comps:
        if not (box.left <= x <= box.right and box.bottom <= y <= box.top):
            print(f"REFUSED  {inst} at ({x},{y}) is outside the die {box}")
            return 2
    print(f"placements: {len(comps)} components, all on the {row} dbu row grid and inside {box}")

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
    moved = copy_shapes(art, art_top, out, top, keep_only_routing=True)
    print(f"top cell: {moved} routed shapes and labels moved to PDK numbers")

    via_cells = {}
    via_count = 0
    for inst in art_top.each_inst():
        name = inst.cell.name
        if name.startswith("VIA"):
            target = via_cells.get(name)
            if target is None:
                target = out.create_cell(name)
                copy_shapes(art, inst.cell, out, target, keep_only_routing=False)
                via_cells[name] = target
            top.insert(db.CellInstArray(target.cell_index(), inst.dcplx_trans))
            via_count += 1
    print(f"vias: {via_count} placements, {len(via_cells)} via cell types rebuilt")

    used = Counter()
    for _inst, cell, x, y, orient in comps:
        target = lib_cells.get(cell)
        if target is None:
            print(f"REFUSED  {cell} is not in the library GDS")
            return 2
        angle, mirror = ORIENT[orient]
        trans = db.Trans(angle, mirror)
        trans.disp = db.Vector(x, y)
        top.insert(db.CellInstArray(target.cell_index(), trans))
        used[cell] += 1
    print(f"cells: {sum(used.values())} placed over {len(used)} types "
          f"(was {sum(1 for i in art_top.each_inst() if i.cell.name.startswith('gf180mcu_fd_sc'))}"
          f" in the artifact)")

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
    for key in ((22, 0), (30, 0), (33, 0), (34, 0), (81, 0)):
        print(f"  layer {key}: {'present' if key in present else 'ABSENT'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
