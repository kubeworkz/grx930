#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Where the 50 unpaired nets sit, and how far each is from a well tap.

Input is `well_nets3.rb`'s TSV (one row per net, identified by its terminal set). The DEF gives
each instance's row and x, and `filltie` placements are the taps. The fill log measured 48,380
taps, 3 rows without one, and a worst cell-to-tap distance of 252 um against a 20 um limit.
"""

import argparse
import collections
import re

ROW_PITCH = 7840


def parse_def(path):
    comps, taps, cells = {}, collections.defaultdict(list), collections.defaultdict(list)
    inside = False
    with open(path, errors="replace") as fh:
        for line in fh:
            s = line.strip()
            if s.startswith("COMPONENTS"):
                inside = True
                continue
            if s.startswith("END COMPONENTS"):
                break
            if not inside:
                continue
            m = re.match(r"-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)", s)
            if not m:
                continue
            inst, cell, x, y = m.group(1), m.group(2), int(m.group(3)), int(m.group(4))
            comps[inst] = (cell.replace("gf180mcu_fd_sc_mcu7t5v0__", ""), x, y)
            cells[int(y)].append((int(x), cell.replace("gf180mcu_fd_sc_mcu7t5v0__", "")))
            if cell.endswith("filltie"):
                taps[y].append(x)
    return comps, taps, cells


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tsv", required=True)
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--top", type=int, default=20)
    args = ap.parse_args()

    comps, taps, cells = parse_def(args.def_file)
    rows = sorted({y for _c, _x, y in comps.values()})
    no_tap = [y for y in rows if y not in taps]

    nets = []
    with open(args.tsv) as fh:
        hdr = next(fh).rstrip("\n").split("\t")
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 7:
                nets.append(dict(zip(hdr, p)))

    buckets = collections.Counter()
    for n in nets:
        inst = [i for i in n["instances"].split(",") if i]
        pts = [comps[i] for i in inst if i in comps]
        ys = sorted({y for _c, _x, y in pts})
        xs = [x for _c, x, _y in pts]
        n["rows"], n["pts"] = ys, pts
        n["xmin"], n["xmax"] = (min(xs), max(xs)) if xs else (0, 0)
        best = None
        for y in ys:
            for x in xs:
                for tx in taps.get(y, []):
                    d = abs(x - tx)
                    best = d if best is None else min(best, d)
        n["tap"] = best
        n["no_tap_row"] = any(y in no_tap for y in ys)
        if best is None:
            buckets["no tap in its row"] += 1
        elif best / 2000 <= 20:
            buckets["tap within 20 um"] += 1
        elif best / 2000 <= 50:
            buckets["tap 20-50 um"] += 1
        else:
            buckets["tap > 50 um"] += 1

    print(f"unpaired nets: {len(nets)}")
    print("nearest tap: " + ", ".join(f"{k}={v}" for k, v in buckets.items()))
    print(f"touch a row without any tap: {sum(1 for n in nets if n['no_tap_row'])}")
    print(f"rows without a tap: {[y // ROW_PITCH for y in no_tap]}")
    print()
    for n in sorted(nets, key=lambda q: -int(q["pairs"]))[: args.top]:
        rowtxt = ",".join(str(y // ROW_PITCH) for y in n["rows"][:5])
        dtxt = "no tap in row" if n["tap"] is None else f"tap {n['tap']/2000:.1f} um"
        print(f"  {n['name']:<16} terms={n['terminals']:<5} pairs={n['pairs']:<4} inst={len(n['pts']):<3} "
              f"row[{rowtxt}] span={(n['xmax']-n['xmin'])/2000:6.1f}um {dtxt:<15} {n['devices']}")


if __name__ == "__main__":
    main()
