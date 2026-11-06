#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Where do the unpaired well nets sit, and how far are they from a well tap?

`dev_mismatch_cause.rb` found 190 device pairs whose bulk sits on a layout net with no schematic
partner, over 45 distinct nets. The fill step placed 48,380 well taps (`filltie`) and reported
3 rows without one and a worst cell-to-tap distance of 252 um against a 20 um limit. This joins the
two: each unpaired net's instances, their rows, and the nearest tap in the same row.

  python3 well_nets.py --cause cause_dev.txt --def filled.def [--top 20]
"""

import argparse
import collections
import re

ROW_PITCH = 7840  # dbu, from the fill log (row pitch 7840 dbu, cell height 7840)


def parse_cause(path):
    nets = collections.defaultdict(lambda: {"inst": set(), "terms": collections.Counter(), "rows": set()})
    with open(path) as fh:
        next(fh, None)
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) < 6:
                continue
            inst, terms = p[2], p[5]
            for m in re.finditer(r"(\d+):(\$[0-9]+)=>[^ ]*\(nil\)", terms):
                nets[m.group(2)]["inst"].add(inst)
                nets[m.group(2)]["terms"][m.group(1)] += 1
    return nets


def parse_def(path):
    comps, taps = {}, collections.defaultdict(list)
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
            comps[inst] = (cell, x, y)
            if cell.endswith("filltie"):
                taps[y].append(x)
    return comps, taps


def main():
    ap = argparse.ArgumentParser(description="Locate the unpaired well nets.")
    ap.add_argument("--cause", required=True)
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--top", type=int, default=20)
    args = ap.parse_args()

    nets = parse_cause(args.cause)
    comps, taps = parse_def(args.def_file)
    rows = sorted({y for _c, _x, y in comps.values()})
    tap_rows = sorted(taps)
    no_tap = [y for y in rows if y not in taps]

    print(f"nets with an unpaired terminal: {len(nets)}")
    print(f"DEF components {len(comps)}, rows {len(rows)}, rows with a tap {len(tap_rows)}, without {len(no_tap)}")
    print("rows without a tap: " + ", ".join(f"y={y} (row {y // ROW_PITCH})" for y in no_tap))

    total_pairs = sum(sum(n['terms'].values()) for n in nets.values())
    print(f"unpaired terminal instances: {total_pairs} (terminal ids {collections.Counter(t for n in nets.values() for t in n['terms'])})")

    placed = [n for n in nets.values() if n["inst"]]
    print(f"nets with a known instance: {len(placed)}/{len(nets)}")

    in_no_tap = 0
    summary = []
    for name, n in nets.items():
        ys = sorted({comps[i][2] for i in n["inst"] if i in comps})
        xs = [comps[i][1] for i in n["inst"] if i in comps]
        cells = collections.Counter(comps[i][0].replace("gf180mcu_fd_sc_mcu7t5v0__", "") for i in n["inst"] if i in comps)
        near = []
        for y in ys:
            if y in taps:
                near.append(min(abs(x - tx) for x in xs if comps_row(x, y, n, comps) for tx in taps[y]))
        dist = min(near) if near else None
        if any(y in no_tap for y in ys):
            in_no_tap += 1
        summary.append((sum(n["terms"].values()), name, len(ys), ys, dist, cells, sorted(n["terms"])))

    summary.sort(reverse=True)
    print(f"nets touching a row without a tap: {in_no_tap}")
    for pairs, name, nrows, ys, dist, cells, tids in summary[: args.top]:
        rowtxt = ",".join(str(y // ROW_PITCH) for y in ys[:6]) + ("..." if len(ys) > 6 else "")
        dtxt = "no tap in row" if dist is None else f"nearest tap {dist / 2000:.1f} um"
        print(f"  {name:<12} pairs={pairs:<3} rows={nrows:<3} row[{rowtxt}] {dtxt} terms={tids} cells={dict(cells)}")


def comps_row(x, y, n, comps):
    return any(comps[i][1] == x and comps[i][2] == y for i in n["inst"] if i in comps)


if __name__ == "__main__":
    main()
