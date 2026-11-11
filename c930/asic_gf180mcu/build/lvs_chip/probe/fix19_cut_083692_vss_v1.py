#!/usr/bin/env python3
"""fix19: remove the remaining _083692_-to-VSS bottom via1.

The fix18 report leaves one giant VSS net containing _083692_.  The DEF
_083692_ route and the tile geometry show one bottom via1 at
(2902200,2574600) landing directly on the M1 VSS rail.  This edit repoints
only that top-level via1 instance to an empty cell, preserving the signal
M1/M2/M3 route and all supply metal.  The input GDS is never overwritten.
"""

import argparse
import hashlib
import json
import os
import sys

import klayout.db as db

TOPCELL = "grx930_test_chip"
V1 = (35, 0)
M1 = (34, 0)
M2 = (36, 0)
M3 = (42, 0)
M2_LABEL = (36, 10)

TARGET = (2_902_200, 2_574_600)
CONTROLS = [
    (2_902_200, 2_577_400),  # signal-side via1, must stay
    (2_906_680, 2_577_400),  # signal-side via1, must stay
]
V1_CELL_PREFIX = "VIA_Via1_"
PROBES = [
    ("M1_VSS_RAIL", M1, TARGET),
    ("M1_SIGNAL_TOP", M1, (2_902_200, 2_577_400)),
    ("M2_RISER", M2, (2_902_200, 2_575_500)),
    ("M2_SMALL_SIGNAL", M2, (2_906_680, 2_577_400)),
    ("M3_SIGNAL_BAR", M3, (2_907_000, 2_577_400)),
    ("M2_LABEL", M2, (3_030_440, 2_576_840)),
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def count_insts(cell, points, prefix):
    counts = [0] * len(points)
    for inst in cell.each_inst():
        if not inst.cell.name.startswith(prefix):
            continue
        d = inst.trans.disp
        for i, (x, y) in enumerate(points):
            if abs(d.x - x) <= 2 and abs(d.y - y) <= 2:
                counts[i] += 1
    return counts


def region_at(layout, cell, layer, point, delta=5):
    li = layout.find_layer(db.LayerInfo(*layer))
    if li is None:
        return None
    reg = db.Region(cell.begin_shapes_rec(li))
    box = db.Box(point[0] - delta, point[1] - delta,
                 point[0] + delta, point[1] + delta)
    return (reg & db.Region(box)).count()


def label_count(layout, cell, layer, text):
    li = layout.find_layer(db.LayerInfo(*layer))
    if li is None:
        return 0
    n = 0
    it = cell.begin_shapes_rec(li)
    while not it.at_end():
        sh = it.shape()
        if sh.is_text() and sh.text is not None and sh.text.string == text:
            n += 1
        it.next()
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gds", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--topcell", default=TOPCELL)
    args = ap.parse_args()

    if os.path.exists(args.out) or os.path.exists(args.report):
        raise SystemExit("refusing to overwrite existing output")

    ly = db.Layout()
    ly.read(args.gds)
    top = ly.cell(args.topcell)
    if top is None:
        raise SystemExit("no cell " + repr(args.topcell))

    target_before = count_insts(top, [TARGET], V1_CELL_PREFIX)[0]
    control_before = count_insts(top, CONTROLS, V1_CELL_PREFIX)
    if target_before != 1:
        raise SystemExit(f"expected one target via1, found {target_before}")
    if control_before != [1, 1]:
        raise SystemExit(f"unexpected control via1 counts before: {control_before}")

    probes_before = {name: region_at(ly, top, layer, pt)
                     for name, layer, pt in PROBES}
    if any(v is None or v == 0 for v in probes_before.values()):
        raise SystemExit(f"pre-edit probe missing: {probes_before}")
    labels_before = label_count(ly, top, M2_LABEL, "_083692_")
    if labels_before != 1:
        raise SystemExit(f"expected one _083692_ label, found {labels_before}")

    v1_li = ly.find_layer(db.LayerInfo(*V1))
    v1_total_before = (db.Region(top.begin_shapes_rec(v1_li))).size()
    v1_target_before = region_at(ly, top, V1, TARGET)
    if not v1_target_before:
        raise SystemExit("target V1 cut missing before edit")

    hits = []
    for inst in top.each_inst():
        if not inst.cell.name.startswith(V1_CELL_PREFIX):
            continue
        d = inst.trans.disp
        if abs(d.x - TARGET[0]) <= 2 and abs(d.y - TARGET[1]) <= 2:
            hits.append(inst)
    if len(hits) != 1:
        raise SystemExit(f"expected one target via1 instance, found {len(hits)}")

    empty = ly.create_cell("EMPTY_FIX19_083692_VSS_V1")
    removed = hits[0]
    removed_record = {
        "cell": removed.cell.name,
        "x": removed.trans.disp.x,
        "y": removed.trans.disp.y,
        "trans": str(removed.trans),
    }
    removed.cell_index = empty.cell_index()
    ly.write(args.out)
    if os.path.getsize(args.out) == 0:
        raise SystemExit("empty output")

    check = db.Layout()
    check.read(args.out)
    ctop = check.cell(args.topcell)
    if ctop is None:
        raise SystemExit("no cell in output")

    target_after = count_insts(ctop, [TARGET], V1_CELL_PREFIX)[0]
    control_after = count_insts(ctop, CONTROLS, V1_CELL_PREFIX)
    if target_after != 0:
        raise SystemExit(f"target via1 still present: {target_after}")
    if control_after != control_before:
        raise SystemExit(f"control via1 changed: {control_before} -> {control_after}")

    v1_li2 = check.find_layer(db.LayerInfo(*V1))
    v1_total_after = (db.Region(ctop.begin_shapes_rec(v1_li2))).size()
    v1_target_after = region_at(check, ctop, V1, TARGET)
    if v1_target_after:
        raise SystemExit(f"target V1 cut still present: count={v1_target_after}")

    probes_after = {name: region_at(check, ctop, layer, pt)
                    for name, layer, pt in PROBES}
    for name, before in probes_before.items():
        after = probes_after[name]
        if not after:
            raise SystemExit(f"probe {name} disappeared: {before} -> {after}")
    labels_after = label_count(check, ctop, M2_LABEL, "_083692_")
    if labels_after != labels_before:
        raise SystemExit(f"_083692_ label changed: {labels_before} -> {labels_after}")

    report = {
        "input": args.gds,
        "input_sha256": sha256(args.gds),
        "output": args.out,
        "output_sha256": sha256(args.out),
        "topcell": args.topcell,
        "removed": removed_record,
        "target": list(TARGET),
        "control_points": [list(p) for p in CONTROLS],
        "target_via1_before": target_before,
        "target_via1_after": target_after,
        "control_via1_before": control_before,
        "control_via1_after": control_after,
        "v1_total_before": v1_total_before,
        "v1_total_after": v1_total_after,
        "v1_target_cut_before": v1_target_before,
        "v1_target_cut_after": v1_target_after,
        "probes_before": probes_before,
        "probes_after": probes_after,
        "label_before": labels_before,
        "label_after": labels_after,
        "note": "removed only the bottom _083692_ via1 at the M1 VSS rail; signal-side via1 and all route metal preserved",
    }
    with open(args.report, "w") as fh:
        json.dump(report, fh, indent=1)
    print(json.dumps(report, indent=1))
    print("WRITE_OK", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
