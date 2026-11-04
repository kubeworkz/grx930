#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Compare the DEF's component positions with the artifact GDS's instances, orientation by orientation.

Why: a DEF pin/component position is the cell's *box* origin. An FS cell is mirrored about x, so in
KLayout it has to be anchored at the top of its row or it lands one row low and its pwell/nwell bands
overlap the row beneath. A synthetic N/FS grid anchored at the DEF origin extracts 0 of 3,072 devices;
the same grid with box anchors extracts 3,072. Which anchor the September artifact used therefore says
whether the stream-out's placement (`build/../tools/lvs_chip/stream_out.py`, `Trans(angle, mirror)`
with `disp = DEF position`) or the artifact is right.

Prints, per DEF orientation, the most common (artifact - DEF) offset in dbu, over a sample of
components (matching by cell type, nearest position). A consistent (0, +3920) for FS means the
artifact anchored mirrored rows at the box top, i.e. one row above the raw DEF y.

Run in the flow image (klayout.db):
    python3 build/lvs_chip/probe/def_vs_artifact_placement.py \
        --gds wafer_space_submission/grx930_test_chip_final.gds --def build/grx930_test_chip.def
"""

import argparse
import collections
import re

import klayout.db as db


def parse_def(path, limit=None):
    out = []
    section = False
    for line in open(path, errors="replace"):
        s = line.strip()
        if s.startswith("COMPONENTS"):
            section = True
            continue
        if s.startswith("END COMPONENTS"):
            break
        if not section:
            continue
        m = re.match(r"-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)", s)
        if m:
            out.append((m.group(2), int(m.group(3)), int(m.group(4)), m.group(5)))
            if limit and len(out) >= limit:
                break
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gds", required=True)
    ap.add_argument("--def", dest="def_path", required=True)
    ap.add_argument("--topcell", default="grx930_test_chip")
    ap.add_argument("--sample", type=int, default=400, help="components per orientation")
    ap.add_argument("--units", type=int, default=2000, help="DEF distance units per micron")
    a = ap.parse_args()

    comps = parse_def(a.def_path)
    ly = db.Layout()
    ly.read(a.gds)
    top = ly.cell(a.topcell)
    if top is None:
        raise SystemExit(f"def_vs_artifact_placement: no top cell {a.topcell}")

    pts = collections.defaultdict(list)
    for inst in top.each_inst():
        t = inst.trans
        pts[inst.cell.name].append((t.disp.x, t.disp.y))

    scale = ly.dbu * a.units          # DEF units -> dbu
    by_orient = collections.Counter()
    deltas = collections.defaultdict(collections.Counter)
    for cell, x, y, o in comps:
        if by_orient[o] >= a.sample:
            continue
        by_orient[o] += 1
        dx_def, dy_def = x / scale if scale != 1 else x, y / scale if scale != 1 else y
        best = min(pts[cell], key=lambda p: abs(p[0] - dx_def) + abs(p[1] - dy_def))
        deltas[o][(round(best[0] - dx_def), round(best[1] - dy_def))] += 1

    print(f"artifact dbu {ly.dbu}, DEF units/um {a.units}, scale {scale:g} dbu per DEF unit")
    for o in sorted(deltas):
        n = sum(deltas[o].values())
        common = deltas[o].most_common(3)
        print(f"{o:2s}: {n:5d} sampled, deltas (dbu) " +
              ", ".join(f"{d}x{c}" for d, c in common))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
