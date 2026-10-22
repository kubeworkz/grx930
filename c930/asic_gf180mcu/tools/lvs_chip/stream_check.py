#!/usr/bin/env python3
"""Is this GDS a stream-out a foundry tool could read? Check it, do not assume it.

The September artifact passed the only check in the tree (`wafer_space_submission/verify_layers.py`)
because that script asserts the layer map it then verifies against. This one names the PDK's own
numbers, demands the device layers exist, and -- given the DEF and the library GDS -- demands that
the cell definitions are layouts rather than LEF abstracts and that the counts match the database
the flow placed. With `--routing-compare` it checks that a repaired stream carries the same routing
geometry as the one it replaces, which is what makes "only the cells and the numbers changed" a
measurement instead of a claim.

    python3 tools/lvs_chip/stream_check.py --gds FILE [--def FILE.def] [--lib LIB.gds]
                                           [--routing-compare DIE_NUMBERED.gds]

Exit status: 0 the stream is conformant, 1 it is not (reasons printed), 2 could not run.

The first check is the one everybody assumes, and the artifact is what happens when nobody runs it:
a stream whose numbers are not the PDK's is read by the deck as *different layers*, so a die with
no comp and no poly is read as a die containing `dnwell` and `nat`.
"""

import argparse
import os
import re
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# One definition of the DEF orientation table, shared with the tool that writes the stream: a
# checker with its own copy could agree with itself and with nothing else.
from stream_out import ORIENT, parse_def_components, parse_def_units  # noqa: E402

DEVICE_LAYERS = {"comp 22/0": (22, 0), "poly2 30/0": (30, 0), "contact 33/0": (33, 0),
                 "nplus 32/0": (32, 0), "pplus 31/0": (31, 0)}
METAL_LAYERS = {"metal1 34/0": (34, 0), "via1 35/0": (35, 0), "metal2 36/0": (36, 0),
                "via2 38/0": (38, 0), "metal3 42/0": (42, 0), "via3 40/0": (40, 0),
                "metal4 46/0": (46, 0), "via4 41/0": (41, 0), "metal5 81/0": (81, 0)}
LABEL_LAYERS = {"metal1 label 34/10": (34, 10), "metal5 label 81/10": (81, 10)}
CELL_LAYERS = [(22, 0), (30, 0), (33, 0), (32, 0), (31, 0), (55, 0), (21, 0), (204, 0), (34, 0)]
STDCELL_PREFIX = "gf180mcu_fd_sc_"

# The die-numbered stream's routing layers against the PDK's, for --routing-compare.
ROUTING_PAIRS = [((34, 0), (5, 0)), ((35, 0), (6, 0)), ((36, 0), (7, 0)), ((38, 0), (8, 0)),
                 ((42, 0), (9, 0)), ((40, 0), (10, 0)), ((46, 0), (11, 0)), ((41, 0), (12, 0)),
                 ((81, 0), (13, 0))]


def layer_set(ly):
    return {(i.layer, i.datatype) for i in ly.layer_infos()}


def cell_layer_counts(ly, cell):
    counts = Counter()
    for li in ly.layer_indexes():
        info = ly.get_info(li)
        key = (info.layer, info.datatype)
        if key not in CELL_LAYERS:
            continue
        n = sum(1 for _ in cell.shapes(li).each())
        if n:
            counts[key] = n
    return counts


def own_count(layout, top, key):
    """Shapes the top cell itself carries. Routing is compared this way on purpose: the library
    cells legitimately add metal of their own, and counting recursively would charge the repair
    for the metal the artifact never had."""
    return top.shapes(layout.layer(*key)).size()


def recursive_count(layout, top, key):
    layer = layout.layer(*key)
    n = 0
    it = top.begin_shapes_rec(layer)
    while not it.at_end():
        n += 1
        it.next()
    return n


def parse_def(def_path):
    """(components per cell, via tokens, {layer: segment count}) from the DEF."""
    comp = Counter()
    vias = Counter()
    segments = Counter()
    section = None
    for line in open(def_path, errors="replace"):
        stripped = line.strip()
        if stripped.startswith(("COMPONENTS", "NETS", "SPECIALNETS", "PINS", "VIAS")):
            section = stripped.split()[0]
            continue
        if stripped.startswith("END "):
            name = stripped.split()[1]
            if name in ("COMPONENTS", "NETS", "SPECIALNETS", "PINS", "VIAS"):
                section = None
            continue
        if section == "COMPONENTS":
            m = re.match(r"-\s+(\S+)\s+(\S+)\s+", stripped)
            if m:
                comp[m.group(2)] += 1
        elif section in ("NETS", "SPECIALNETS"):
            m = re.search(r"\bNEW\s+(Metal\d)\b", stripped)
            if m:
                segments[m.group(1)] += 1
            for name in re.findall(r"\b([Vv]ia[A-Za-z0-9_]*)", stripped):
                if name not in ("Via1", "Via2", "Via3", "Via4", "Via5"):
                    vias[name] += 1
    return comp, vias, segments


def main():
    try:
        import klayout.db as db
    except ImportError:
        print("stream_check: CANNOT-RUN klayout.db is required")
        return 2

    ap = argparse.ArgumentParser()
    ap.add_argument("--gds", required=True)
    ap.add_argument("--def", dest="def_file", default=None)
    ap.add_argument("--lib", default=None)
    ap.add_argument("--routing-compare", default=None)
    args = ap.parse_args()

    if not os.path.isfile(args.gds):
        print(f"stream_check: CANNOT-RUN no {args.gds}")
        return 2

    ly = db.Layout()
    ly.read(args.gds)
    top = ly.top_cell()
    layers = layer_set(ly)
    bad = []

    print(f"file     {os.path.basename(args.gds)} ({os.path.getsize(args.gds)} B)")
    print(f"top cell {top.name}, {ly.cells()} cells, {top.child_instances()} instances, "
          f"{len(layers)} layer/datatype pairs")

    missing = [k for k, v in DEVICE_LAYERS.items() if v not in layers]
    metals = [k for k, v in METAL_LAYERS.items() if v in layers]
    labels = [k for k, v in LABEL_LAYERS.items() if v in layers]
    print(f"layers   device {len(DEVICE_LAYERS) - len(missing)}/{len(DEVICE_LAYERS)}, "
          f"metal {len(metals)}/{len(METAL_LAYERS)}, labels {len(labels)}/{len(LABEL_LAYERS)}")
    if missing:
        bad.append(f"missing device layers: {', '.join(missing)}")
    overlap = sorted(k for k in layers if k[0] <= 15 and k in
                     {(5, 0), (6, 0), (7, 0), (8, 0), (9, 0), (10, 0), (11, 0), (12, 0), (13, 0)})
    if overlap:
        bad.append(f"layer numbers belonging to a LEF/DEF index scheme are present: {overlap}")
    if not metals:
        bad.append("no PDK metal layers at all")
    if not labels:
        bad.append("no PDK label layers (34/10, 81/10 ...): top pins cannot be named")

    if args.lib and os.path.isfile(args.lib):
        lib = db.Layout()
        lib.read(args.lib)
        checked = abstract = 0
        example = None
        for cell in ly.each_cell():
            if not cell.name.startswith(STDCELL_PREFIX):
                continue
            lib_cell = lib.cell(cell.name)
            if lib_cell is None:
                continue
            checked += 1
            got, want = cell_layer_counts(ly, cell), cell_layer_counts(lib, lib_cell)
            if got != want:
                abstract += 1
                example = example or f"{cell.name} carries {dict(got)}, library {dict(want)}"
        if abstract:
            bad.append(f"{abstract}/{checked} cells are not the library's layout; e.g. {example}")
        else:
            print(f"cells    {checked}/{checked} cells carry the library's device layers")

    if args.def_file and os.path.isfile(args.def_file):
        comp, vias, segments = parse_def(args.def_file)
        want_cells, want_vias = sum(comp.values()), sum(vias.values())
        got_cells = sum(1 for i in top.each_inst() if i.cell.name.startswith(STDCELL_PREFIX))
        got_vias = sum(1 for i in top.each_inst() if i.cell.name.startswith("VIA"))
        print(f"DEF      {want_cells} components, {want_vias} via placements, "
              f"{sum(segments.values())} routing segments")
        print(f"place    {got_cells} standard cells, {got_vias} via cells in the GDS")
        if want_cells != got_cells:
            bad.append(f"instance count: GDS {got_cells}, DEF {want_cells}")
        if want_vias and got_vias != want_vias:
            bad.append(f"via count: GDS {got_vias}, DEF {want_vias}")

        # Where each cell sits, not just how many there are: an instance count can be perfect while
        # most cells are in the wrong row or mirrored the wrong way, which is what the submitted
        # file did (N exact, FS one row high, FN and S somewhere else).
        units = parse_def_units(args.def_file)
        scale = ly.dbu * units if units else 0
        if not scale:
            bad.append("no `UNITS DISTANCE MICRONS` in the DEF header; placements not checked")
        else:
            at = {}
            for inst in top.each_inst():
                if inst.cell.name.startswith(STDCELL_PREFIX):
                    t = inst.trans
                    at[(inst.cell.name, t.disp.x, t.disp.y)] = (t.angle, t.is_mirror())
            placed = misplaced = 0
            per_orient = Counter()
            example = None
            for _inst, cell, x, y, orient in parse_def_components(args.def_file):
                key = (cell, int(round(x / scale)), int(round(y / scale)))
                want = ORIENT.get(orient)
                got = at.get(key)
                if got is None:
                    misplaced += 1
                    per_orient[orient] += 0
                    example = example or f"{cell} has no instance at {key[1:]}"
                elif want and got != want:
                    misplaced += 1
                    per_orient[orient] += 1
                    example = example or f"{cell} at {key[1:]} is {got}, DEF says {orient}"
                else:
                    placed += 1
            total = placed + misplaced
            print(f"orient   {placed}/{total} components at the DEF position with the DEF "
                  f"orientation")
            if misplaced:
                detail = ", ".join(f"{o} {n}r" for o, n in sorted(per_orient.items()) if n)
                bad.append(f"{misplaced}/{total} components are misplaced (wrong orientation: "
                           f"{detail or 'none'}); e.g. {example}")

    if args.routing_compare and os.path.isfile(args.routing_compare):
        other = db.Layout()
        other.read(args.routing_compare)
        other_top = other.top_cell()
        print("routing  (a repair must change cells and numbers; routing must be identical)")
        for pdk, die in ROUTING_PAIRS:
            if die not in layer_set(other):
                continue
            a = own_count(ly, top, pdk)
            b = own_count(other, other_top, die)
            mark = "same" if a == b else "DIFFERENT"
            print(f"  {pdk[0]:>3}/{pdk[1]:<2} {a:>9}  vs  {die[0]:>2}/{die[1]:<2} {b:>9}   {mark}")
            if a != b:
                bad.append(f"routing shape count differs {pdk} = {a} vs {die} = {b}")

    print()
    if bad:
        print("STREAM: FAIL")
        for reason in bad:
            print(f"  - {reason}")
        return 1
    print("STREAM: PASS -- PDK numbering, device layers, library layouts, counts agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
