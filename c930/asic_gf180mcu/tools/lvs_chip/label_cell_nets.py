#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Name the streamed die's standard-cell internal nets the way the schematic names them.

The die comparison leaves 242 device pairs at `Mismatch`. Their parameters agree and their geometry
agrees; what differs is the *net* under each terminal (`$373931` against `_75713_.NCKI`). A cell's
internal nets are never routed, so the DEF has no name for them and the streamed layout has none
either, while the schematic got its names from the library CDL. KLayout's comparer uses net names as
a hint (`consider_net_names`), so naming the layout's internal nets is what can let it confirm those
pairs instead of guessing.

Three measurements decide the shape of this tool:

  * labels inside a cell *definition* are not enough. Written that way, the die netlist carried
    14,483 nets named bare `NCKI`: the flatten does not prefix a label with the instance it sits in,
    so the name stops identifying anything and the pair counts did not move (370,046 nets /
    690,114 devices, identical to the unlabelled die). The name has to be written per instance, in
    the top cell, as `<instance>.<net>` -- the string the schematic already carries;
  * a label only names a net when it sits on one of that net's shapes. The positions come from
    `build/lvs_chip/probe/cell_label_map.rb`, which takes them from the cell's *drawn* metal (a layer
    whose region XOR the drawn layer is empty) after a cell-level comparison verified the pairing.
    A cell-definition label was checked that way by re-running the cell comparison: 6 of 6 labels
    landed on the net they name, 0 on another;
  * an instance is identified by its own placement, not by list order. The die's DEF and the
    streamed layout disagree on COMPONENTS order (the stream is made from the filled DEF), so each
    DEF placement is anchored exactly as `stream_out.py` anchors it and looked up by
    (cell, anchor). Counts and lookups must both be exact or the tool refuses.

    python3 tools/lvs_chip/label_cell_nets.py --gds IN.gds --def-file PLACED.def --maps DIR --out OUT.gds

Each `DIR/**/map.json` is one cell map: `{"cell": ..., "dbu": ..., "nets": {name: {layer, x, y}}}`.
Exit status: 0 written, 2 refused.
"""

import argparse
import glob
import json
import os
import re
import sys
from collections import Counter

# DEF orientation -> KLayout Trans, as in stream_out.py: the integer is quarter turns, `mirror` is
# about the x axis, which is what the DEF's F* orientations mean.
ORIENT = {"N": (0, False), "W": (1, False), "S": (2, False), "E": (3, False),
          "FN": (2, True), "FS": (0, True), "FW": (1, True), "FE": (3, True)}


def load_maps(path):
    """All cell maps under a file or directory, keyed by cell name.

    A run directory holds `verdict.json` and `map.json` side by side, so files that are not maps are
    skipped rather than refused; a directory with no map at all is still an error at the caller.
    """
    if os.path.isfile(path):
        files = [path]
    else:
        files = sorted(glob.glob(os.path.join(path, "**", "*.json"), recursive=True))
    maps = {}
    for f in files:
        try:
            with open(f) as fh:
                m = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(m, dict) or not m.get("cell"):
            continue
        for name, spec in m.get("nets", {}).items():
            if not isinstance(spec, dict) or "layer" not in spec or "x" not in spec:
                print(f"REFUSED  {f}: net {name} is not a {{layer,x,y}} entry", file=sys.stderr)
                return None
        maps[m["cell"]] = m
    return maps


def parse_def(path):
    """(units, [(inst, cell, x, y, orient)]) from the DEF header and COMPONENTS."""
    units = 0
    comps = []
    section = None
    with open(path, errors="replace") as fh:
        for line in fh:
            s = line.strip()
            if not units:
                m = re.match(r"UNITS\s+DISTANCE\s+MICRONS\s+(\d+)", s)
                if m:
                    units = int(m.group(1))
            if s.startswith("COMPONENTS"):
                section = "comp"
                continue
            if s.startswith("END COMPONENTS"):
                break
            if section != "comp":
                continue
            m = re.match(r"-\s+(\S+)\s+(\S+)\s+.*?\b(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)", s)
            if m:
                comps.append((m.group(1), m.group(2), int(m.group(3)), int(m.group(4)), m.group(5)))
    return units, comps


def main():
    ap = argparse.ArgumentParser(description="Name standard-cell internal nets per instance.")
    ap.add_argument("--gds", required=True, help="streamed layout (stream_out*.gds)")
    ap.add_argument("--def-file", required=True, help="DEF whose COMPONENTS name the instances")
    ap.add_argument("--maps", required=True, help="cell map JSON, or a directory of them")
    ap.add_argument("--out", required=True, help="labelled layout to write")
    ap.add_argument("--report", default=None, help="optional per-cell report")
    args = ap.parse_args()

    try:
        import klayout.db as db
    except ImportError:
        print("CANNOT-RUN  klayout.db is required (run inside the flow image)", file=sys.stderr)
        return 2

    maps = load_maps(args.maps)
    if not maps:
        print(f"REFUSED  no cell maps under {args.maps}", file=sys.stderr)
        return 2
    mapped = {c for c, m in maps.items() if m.get("nets")}
    if not mapped:
        print("REFUSED  every map is empty: nothing to name", file=sys.stderr)
        return 2

    layout = db.Layout()
    layout.read(args.gds)
    top = layout.top_cell()
    if top is None:
        print("REFUSED  layout has no top cell", file=sys.stderr)
        return 2

    units, raw = parse_def(args.def_file)
    if not units:
        print(f"REFUSED  no `UNITS DISTANCE MICRONS` in {args.def_file}", file=sys.stderr)
        return 2
    scale = layout.dbu * units
    comps = [(inst, cell, int(round(x / scale)), int(round(y / scale)), orient)
             for inst, cell, x, y, orient in raw if cell in mapped]
    def_count = Counter(cell for _i, cell, _x, _y, _o in comps)
    print(f"DEF  {len(comps)} placements over {len(def_count)} mapped cell types "
          f"(units {units}/um, scale {scale:g})")

    # Instance lookup by anchored placement. The anchor rule is stream_out.py's: the DEF point is
    # the cell's box corner, so a mirrored/rotated copy is translated until its box lands on the
    # row the DEF names. The box is layer 0/0, not the drawn bbox (cells draw their wells 0.43 um
    # beyond the boundary).
    box_layer = layout.find_layer(0, 0)
    if box_layer is None:
        print("REFUSED  the layout has no layer 0/0 cell boundary, so the anchor is unknown",
              file=sys.stderr)
        return 2
    sizes = {}
    for cell_name in mapped:
        c = layout.cell(cell_name)
        if c is None:
            print(f"REFUSED  cell not in this layout: {cell_name}", file=sys.stderr)
            return 2
        sb = c.bbox(box_layer)
        if sb.empty():
            print(f"REFUSED  {cell_name} has no layer 0/0 box", file=sys.stderr)
            return 2
        sizes[cell_name] = (sb.width(), sb.height())

    placed = {}
    for inst_name, cell, x, y, orient in comps:
        w, h = sizes[cell]
        angle, mirror = ORIENT[orient]
        trans = db.Trans(angle, mirror)
        corners = [trans * db.Point(px, py) for px in (0, w) for py in (0, h)]
        trans.disp = db.Vector(x - min(p.x for p in corners), y - min(p.y for p in corners))
        # Key on the placed *box*, not the anchor: a mirrored copy at (x, y) and a normal copy at
        # (x + w, y + h) share an anchor point but not a box (measured: _38455_ S and _38934_ N on
        # aoi22_1), and two boxes that coincide would be an overlap.
        key = (cell, min(p.x for p in corners) + trans.disp.x,
               min(p.y for p in corners) + trans.disp.y)
        if key in placed:
            print(f"REFUSED  two placements anchor at the same point: {inst_name} and "
                  f"{placed[key][0]}", file=sys.stderr)
            return 2
        placed[key] = (inst_name, trans)

    insts = {}
    for inst in top.each_inst():
        cell = inst.cell.name
        if cell not in mapped:
            continue
        w, h = sizes[cell]
        for t in inst.cell_inst.each_cplx_trans():
            corners = [t * db.Point(px, py) for px in (0, w) for py in (0, h)]
            key = (cell, min(p.x for p in corners), min(p.y for p in corners))
            if key in insts:
                print(f"REFUSED  layout has two instances anchored at {key}", file=sys.stderr)
                return 2
            insts[key] = t
    gds_count = Counter(cell for cell, _x, _y in insts)
    print(f"GDS  {len(insts)} instances over {len(gds_count)} mapped cell types")

    if def_count != gds_count:
        diff = {c: (def_count.get(c, 0), gds_count.get(c, 0))
                for c in set(def_count) | set(gds_count)
                if def_count.get(c, 0) != gds_count.get(c, 0)}
        print(f"REFUSED  DEF and layout place different numbers of these cells: {diff}", file=sys.stderr)
        return 2
    unplaced = [k for k in placed if k not in insts]
    if unplaced:
        print(f"REFUSED  {len(unplaced)} DEF placements have no layout instance, e.g. {unplaced[0]}",
              file=sys.stderr)
        return 2

    # Idempotence without a quadratic scan: the stream already carries ~54k DEF labels on these
    # layers, so the existing texts are indexed once and checked by (name, position).
    existing = {}

    def texts_on(li):
        if li not in existing:
            existing[li] = {(sh.text_string, sh.text_trans.disp.x, sh.text_trans.disp.y)
                            for sh in top.shapes(li).each() if sh.is_text()}
        return existing[li]

    written = 0
    report = []
    for inst_name, cell, _x, _y, _orient in comps:
        m = maps[cell]
        mscale = (m.get("dbu") or layout.dbu) / layout.dbu
        w, h = sizes[cell]
        angle, mirror = ORIENT[_orient]
        trans = db.Trans(angle, mirror)
        corners = [trans * db.Point(px, py) for px in (0, w) for py in (0, h)]
        trans.disp = db.Vector(_x - min(p.x for p in corners), _y - min(p.y for p in corners))
        n = 0
        for net, spec in m["nets"].items():
            layer, datatype = spec["layer"]
            li = layout.layer(int(layer), int(datatype))
            pt = trans * db.Point(int(round(spec["x"] * mscale)), int(round(spec["y"] * mscale)))
            name = f"{inst_name}.{net}"
            have = texts_on(li)
            if (name, pt.x, pt.y) in have:
                continue
            top.shapes(li).insert(db.Text(name, db.Trans(pt.x, pt.y)))
            have.add((name, pt.x, pt.y))
            n += 1
        written += n
        report.append((inst_name, cell, n))

    layout.write(args.out)
    print(f"wrote {args.out}: {written} instance-qualified net labels over {len(comps)} instances")
    if args.report:
        with open(args.report, "w") as fh:
            for inst_name, cell, n in report:
                fh.write(f"{inst_name}\t{cell}\t{n}\n")
        print(f"report {args.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
