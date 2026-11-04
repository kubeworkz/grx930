# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""How many PFET bodies and VDD source/drains sit on the two rail islands the clock reaches.

The pre-stitch clock net carries 301 `pfet_05v0/3` (body) and 195 `pfet_05v0/0|/2` (source/drain)
terminals besides its 28,988 gates.  If the two contacts really are the rail islands the probe
found, the cells whose VDD pin abuts those islands must account for those terminals: every PFET in
them contributes one body, and each PFET source/drain the library ties to VDD contributes another.

    python3 island_bodies.py --def ...filled_metal1.def --lef ../../cells.lef \\
        --cdl ../grx930_test_chip.cdl --line 1536640:2192960:2210230 --line 2242240:1426880:1757750
"""

import argparse
import re

import klayout.db as db

COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)")
UPRIGHT = ("N", "FN")


def lef_sizes(path):
    sizes = {}
    name = None
    for line in open(path, errors="replace"):
        s = line.strip()
        m = re.match(r"MACRO (\S+)", s)
        if m:
            name = m.group(1)
            continue
        m = re.match(r"SIZE ([\d.]+) BY ([\d.]+)", s)
        if m and name:
            sizes[name] = (round(float(m.group(1)) * 1000), round(float(m.group(2)) * 1000))
        if name and s == "END " + name:
            name = None
    return sizes


def cdl_devices(path):
    """{cell: (pfets, vdd_source_drains)} from the appended library block."""
    out = {}
    cur = None
    for line in open(path, errors="replace"):
        s = line.strip()
        if s.startswith(".SUBCKT "):
            cur = s.split()[1]
            out[cur] = [0, 0]
            continue
        if s.startswith(".ENDS"):
            cur = None
            continue
        if cur is None or not s.startswith("M"):
            continue
        tok = s.split()
        if "pfet" not in tok[-3] and "pfet" not in tok[-1]:
            continue
        out[cur][0] += 1
        # M name D G S B model ... : a source/drain tied to VDD is a terminal on that rail
        if len(tok) >= 6 and "VDD" in (tok[1], tok[3]):
            out[cur][1] += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--lef", required=True)
    ap.add_argument("--cdl", required=True)
    ap.add_argument("--line", action="append", required=True,
                    help="rail line:island_x0:island_x1, in dbu")
    args = ap.parse_args()

    sizes = lef_sizes(args.lef)
    dev = cdl_devices(args.cdl)
    comps = []
    for line in open(args.def_file, errors="replace"):
        m = COMP_RE.match(line.strip())
        if m:
            comps.append((m.group(1), m.group(2), int(m.group(3)) // 2, int(m.group(4)) // 2,
                          m.group(5)))
    print(f"components={len(comps)} cdl cells={len(dev)}")

    total_b = total_s = 0
    for spec in args.line:
        yline, x0, x1 = (int(v) for v in spec.split(":"))
        on = []
        for inst, cell, x, y, orient in comps:
            size = sizes.get(cell)
            if not size:
                continue
            w, h = size
            up = orient in UPRIGHT
            vdd_y = (y + h) if up else y
            if vdd_y != yline:
                continue
            if x + w <= x0 or x >= x1:
                continue
            on.append((inst, cell, x, w))
        bodies = sum(dev.get(c[1], (0, 0))[0] for c in on)
        sd = sum(dev.get(c[1], (0, 0))[1] for c in on)
        kinds = {}
        for _i, c, _x, _w in on:
            kinds[c] = kinds.get(c, 0) + 1
        print(f"\nrail line y={yline} ({yline / 1000:.3f} um) island x {x0}..{x1} "
              f"({(x1 - x0) / 1000:.3f} um): {len(on)} cells")
        print(f"  PFET bodies {bodies}, PFET source/drains on VDD {sd}")
        top = sorted(kinds.items(), key=lambda t: -t[1])[:6]
        print("  cells: " + ", ".join(f"{k.replace('gf180mcu_fd_sc_mcu7t5v0__', '')} x{v}"
                                      for k, v in top))
        total_b += bodies
        total_s += sd
    print(f"\nboth islands: {total_b} PFET bodies, {total_s} PFET source/drains on VDD")
    print("netlist clock net: 301 bodies, 195 source/drains")


if __name__ == "__main__":
    main()
