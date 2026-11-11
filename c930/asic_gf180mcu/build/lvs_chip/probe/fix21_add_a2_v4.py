#!/usr/bin/env python3
"""fix21: add the missing V4 at the A2/_076858_ M4-M5 crossing.

The fix20 LVS pair is A2 (2 terms) <-> _076858_ (36 terms).  A2's long M4
bar runs east from (1869980,1474620).  It reaches the existing V4 at
(1870010,1475880), which connects it to the M5 strap at y=1475880.  That M5
strap crosses the _076858_ M4 bar at x=1843800, but there is no V4 at the
crossing.  fix21 inserts one copy of the existing V4 cell there.  It does not
remove or move any existing geometry.
"""

import argparse
import hashlib
import json
import os
import sys

import klayout.db as db

TOPCELL = "grx930_test_chip"
V4_LAYER = (41, 0)
M4_LAYER = (46, 0)
M5_LAYER = (81, 0)
V4_CELL = "VIA_via4_5_3200_6400_4_2_1240_1240"
TARGET = (1_843_800, 1_475_880)
EXISTING = (1_870_010, 1_475_880)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def region_at(layout, cell, layer, point, delta=5):
    li = layout.find_layer(db.LayerInfo(*layer))
    if li is None:
        return 0
    reg = db.Region(cell.begin_shapes_rec(li))
    box = db.Box(point[0] - delta, point[1] - delta,
                 point[0] + delta, point[1] + delta)
    return (reg & db.Region(box)).count()


def instances_at(cell, point, prefix):
    rows = []
    for inst in cell.each_inst():
        if not inst.cell.name.startswith(prefix):
            continue
        d = inst.trans.disp
        if abs(d.x - point[0]) <= 2 and abs(d.y - point[1]) <= 2:
            rows.append(inst)
    return rows


def count_cell(cell, name):
    return sum(1 for inst in cell.each_inst() if inst.cell.name == name)


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

    v4_hits_before = region_at(ly, top, V4_LAYER, TARGET)
    m4_hits_before = region_at(ly, top, M4_LAYER, TARGET)
    m5_hits_before = region_at(ly, top, M5_LAYER, TARGET)
    existing_hits_before = region_at(ly, top, V4_LAYER, EXISTING)
    if existing_hits_before == 0:
        raise SystemExit(f"no A2-side V4 at {EXISTING}")
    if v4_hits_before != 0:
        raise SystemExit(f"target already has V4 geometry: {v4_hits_before}")
    if not m4_hits_before or not m5_hits_before:
        raise SystemExit(
            f"target M4/M5 missing: M4={m4_hits_before} M5={m5_hits_before}")

    v4_li = ly.find_layer(db.LayerInfo(*V4_LAYER))
    if v4_li is None:
        raise SystemExit("no V4 layer in GDS")
    # The available VIA_via4 cell is an 8-cut array with a central hole; its
    # cuts do not overlap both target metals.  Add one standard 260x260 cut.
    half = 130
    top.shapes(v4_li).insert(db.Box(
        TARGET[0] - half, TARGET[1] - half,
        TARGET[0] + half, TARGET[1] + half,
    ))

    ly.write(args.out)
    if os.path.getsize(args.out) == 0:
        raise SystemExit("empty output")

    check = db.Layout()
    check.read(args.out)
    ctop = check.cell(args.topcell)
    if ctop is None:
        raise SystemExit("no top cell in output")

    v4_hits_after = region_at(check, ctop, V4_LAYER, TARGET)
    m4_hits_after = region_at(check, ctop, M4_LAYER, TARGET)
    m5_hits_after = region_at(check, ctop, M5_LAYER, TARGET)
    existing_hits_after = region_at(check, ctop, V4_LAYER, EXISTING)
    if v4_hits_after != 1:
        raise SystemExit(f"target V4 count is {v4_hits_after}, expected 1")
    if m4_hits_after < m4_hits_before or m5_hits_after < m5_hits_before:
        raise SystemExit(
            f"target metal lost: M4 {m4_hits_before}->{m4_hits_after}, "
            f"M5 {m5_hits_before}->{m5_hits_after}")
    if existing_hits_after != existing_hits_before:
        raise SystemExit(
            f"A2-side V4 changed: {existing_hits_before}->{existing_hits_after}")

    report = {
        "input": args.gds,
        "input_sha256": sha256(args.gds),
        "output": args.out,
        "output_sha256": sha256(args.out),
        "topcell": top.name,
        "via_cell": "raw 260x260 V4 cut at target",
        "target": list(TARGET),
        "existing_a2_v4": [EXISTING[0], EXISTING[1]],
        "existing_a2_v4_hits": [existing_hits_before, existing_hits_after],
        "target_v4_before": v4_hits_before,
        "target_v4_after": v4_hits_after,
        "target_m4_hits": [m4_hits_before, m4_hits_after],
        "target_m5_hits": [m5_hits_before, m5_hits_after],
        "note": "inserted exactly one raw 260x260 V4 cut at the A2 M5 / _076858_ M4 crossing; no metal or existing via was changed",
    }
    with open(args.report, "w") as fh:
        json.dump(report, fh, indent=1)
    print(json.dumps(report, indent=1))
    print("WRITE_OK", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
