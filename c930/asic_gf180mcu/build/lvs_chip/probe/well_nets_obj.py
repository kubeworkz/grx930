#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Locate each unpaired net *object* (not name) on the die: rows, span, nearest well tap.

Input is `well_net_trace.rb`'s TSV, whose first column is the layout net object id, so two nets
that happen to share a name stay separate. The DEF gives each instance's row and x; `filltie`
placements are the taps. The fill log measured 48,380 taps, 3 rows without one, worst cell-to-tap
252 um against a 20 um limit -- this says which of those the unpaired wells sit in.

  python3 well_nets_obj.py --tsv well_nets.tsv --def filled.def [--top 25]
"""

import argparse
import collections
import re

ROW_PITCH = 7840


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
            comps[inst] = (cell.replace("gf180mcu_fd_sc_mcu7t5v0__", ""), x, y)
            if cell.endswith("filltie"):
                taps[y].append(x)
    return comps, taps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tsv", required=True)
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--top", type=int, default=25)
    args = ap.parse_args()

    comps, taps = parse_def(args.def_file)
    rows = sorted({y for _c, _x, y in comps.values()})
    no_tap = [y for y in rows if y not in taps]

    nets = []
    with open(args.tsv) as fh:
        hdr = next(fh).rstrip("\n").split("\t")
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) < 7:
                continue
            nets.append(dict(zip(hdr, p)))

    inside_taprow = collections.Counter()
    dist_buckets = collections.Counter()
    spans = []
    for n in nets:
        inst = [i for i in n["instances"].split(",") if i]
        pts = [comps[i] for i in inst if i in comps]
        ys = sorted({y for _c, _x, y in pts})
        xs = [x for _c, x, _y in pts]
        n["n_inst"] = len(inst)
        n["rows"] = ys
        n["xmin"], n["xmax"] = (min(xs), max(xs)) if xs else (0, 0)
        best = None
        for y in ys:
            if y in taps:
                for x in xs:
                    d = min(abs(x - tx) for tx in taps[y])
                    best = d if best is None else min(best, d)
        n["tap_dist"] = best
        n["in_no_tap"] = any(y in no_tap for y in ys)
        if n["in_no_tap"]:
            inside_taprow[n["name"]] += 1
        if best is None:
            dist_buckets["no tap in row"] += 1
        elif best / 2000.0 <= 20:
            dist_buckets["<=20 um"] += 1
        elif best / 2000.0 <= 50:
            dist_buckets["20-50 um"] += 1
        else:
            dist_buckets[">50 um"] += 1
        spans.append((n["xmax"] - n["xmin"]) / 2000.0)

    print(f"unpaired net objects: {len(nets)}")
    print("nearest-tap distance: " + ", ".join(f"{k}={v}" for k, v in dist_buckets.items()))
    print(f"nets touching one of the 3 tap-less rows: {sum(1 for n in nets if n['in_no_tap'])}")
    print(f"row span of the net's instances: median {sorted(spans)[len(spans)//2]:.1f} um, max {max(spans):.1f} um")
    print()
    for n in sorted(nets, key=lambda q: -int(q["pairs"]))[: args.top]:
        rowtxt = ",".join(str(y // ROW_PITCH) for y in n["rows"][:6])
        dtxt = "no tap in row" if n["tap_dist"] is None else f"tap {n['tap_dist']/2000:.1f} um"
        print(f"  {n['name']:<12} pairs={n['pairs']:<3} terms={n['terminals']:<4} inst={n['n_inst']:<3} "
              f"row[{rowtxt}] span={(n['xmax']-n['xmin'])/2000:6.1f}um {dtxt:<16} {n['devices']}")


if __name__ == "__main__":
    main()
