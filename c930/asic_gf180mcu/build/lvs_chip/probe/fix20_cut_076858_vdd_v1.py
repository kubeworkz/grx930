#!/usr/bin/env python3
"""fix20: remove only the final _076858_ VDD tap.

The fix19 M1-M5 trace reaches VDD from the _076858_ M2 label through a
signal route and then via1 (1846600,1480920) onto the M1 VDD rail.  This edit
removes that one VIA_Via1_HV instance; the two signal-side via1s and all route
metal/labels are preserved.  Input is fix19; fix19 and earlier are untouched.
"""

import argparse
import hashlib
import json
import os
import sys

import klayout.db as db

TOPCELL = "grx930_test_chip"
TARGET = (1_846_600, 1_480_920)
CONTROL_V1 = [(1_843_800, 1_483_720), (1_815_240, 1_483_720)]
LABEL = "_076858_"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def count_insts(cell, points, prefix):
    out = [0] * len(points)
    for inst in cell.each_inst():
        if not inst.cell.name.startswith(prefix):
            continue
        d = inst.trans.disp
        for i, (x, y) in enumerate(points):
            if abs(d.x - x) <= 2 and abs(d.y - y) <= 2:
                out[i] += 1
    return out


def count_prefix(cell, prefix):
    return sum(1 for inst in cell.each_inst()
               if inst.cell.name.startswith(prefix))


def hits(region, x, y):
    return (region & db.Region(db.Box(x - 5, y - 5, x + 5, y + 5))).count()


def label_count(layout, cell):
    n = 0
    for li in layout.layer_indexes():
        info = layout.get_info(li)
        if info.layer != 36 or info.datatype != 10:
            continue
        for sh in cell.shapes(li).each():
            if sh.is_text() and sh.text is not None and sh.text.string == LABEL:
                n += 1
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
        raise SystemExit(f"no cell {args.topcell!r}")

    target_before = count_insts(top, [TARGET], "VIA_Via1_")
    controls_before = count_insts(top, CONTROL_V1, "VIA_Via1_")
    v1_total_before = count_prefix(top, "VIA_Via1_")
    labels_before = label_count(ly, top)
    if target_before != [1]:
        raise SystemExit(f"expected exactly one V1 at {TARGET}, found {target_before}")
    if controls_before != [1, 1]:
        raise SystemExit(f"signal-side V1 controls changed: {controls_before}")
    if labels_before != 1:
        raise SystemExit(f"expected one {LABEL} label, found {labels_before}")

    kept = []
    removed = []
    for inst in top.each_inst():
        d = inst.trans.disp
        if (inst.cell.name.startswith("VIA_Via1_")
                and abs(d.x - TARGET[0]) <= 2 and abs(d.y - TARGET[1]) <= 2):
            removed.append({"cell": inst.cell.name, "x": d.x, "y": d.y,
                            "trans": str(inst.trans)})
            continue
        kept.append(inst.cell_inst)
    if len(removed) != 1:
        raise SystemExit(f"expected to remove one V1, removed {len(removed)}")
    top.clear_insts()
    for ci in kept:
        top.insert(ci)

    ly.write(args.out)
    if os.path.getsize(args.out) == 0:
        raise SystemExit("empty output")

    check = db.Layout()
    check.read(args.out)
    ctop = check.cell(args.topcell)
    target_after = count_insts(ctop, [TARGET], "VIA_Via1_")
    controls_after = count_insts(ctop, CONTROL_V1, "VIA_Via1_")
    v1_total_after = count_prefix(ctop, "VIA_Via1_")
    labels_after = label_count(check, ctop)
    if target_after != [0]:
        raise SystemExit(f"target V1 remains: {target_after}")
    if controls_after != controls_before:
        raise SystemExit(f"signal-side V1 changed: {controls_before} -> {controls_after}")
    if v1_total_after != v1_total_before - 1:
        raise SystemExit(f"unexpected V1 total: {v1_total_before} -> {v1_total_after}")
    if labels_after != labels_before:
        raise SystemExit(f"{LABEL} label changed: {labels_before} -> {labels_after}")

    m1 = db.Region(ctop.begin_shapes_rec(check.layer(34, 0)))
    m2 = db.Region(ctop.begin_shapes_rec(check.layer(36, 0)))
    m1_target = hits(m1, *TARGET)
    m2_target = hits(m2, *TARGET)
    if m1_target == 0:
        raise SystemExit("M1 VDD rail missing at target after edit")
    if m2_target == 0:
        raise SystemExit("M2 signal route missing at target after edit")

    report = {
        "input": args.gds,
        "input_sha256": sha256(args.gds),
        "output": args.out,
        "output_sha256": sha256(args.out),
        "topcell": top.name,
        "target": list(TARGET),
        "control_signal_v1": [list(p) for p in CONTROL_V1],
        "removed": removed,
        "target_v1_before": target_before,
        "target_v1_after": target_after,
        "control_v1_before": controls_before,
        "control_v1_after": controls_after,
        "v1_total_before": v1_total_before,
        "v1_total_after": v1_total_after,
        "label_before": labels_before,
        "label_after": labels_after,
        "m1_rail_hit": m1_target,
        "m2_route_hit": m2_target,
        "note": "removed only the final _076858_ VDD via1 at (1846600,1480920); signal-side via1s and route metal preserved",
    }
    with open(args.report, "w") as fh:
        json.dump(report, fh, indent=1)
    print(json.dumps(report, indent=1))
    print("WRITE_OK", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
