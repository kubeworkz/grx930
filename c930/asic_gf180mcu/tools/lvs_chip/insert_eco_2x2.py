#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Insert the Stage 6 2x2 ECO drops into the filled DEF and write the ODB.

The site list is the one find_eco_sites.py froze: `name,x,y,ty,kind,...` in GDS
database units (1 nm).  The geometry is the one build_row_crops.rb puts in the GDS,
so the DEF and the GDS cannot disagree:

  M1 landing   x +/- 450, y +/- 390      (the Via1 LEF definition's Metal1 rect)
  M3 landing   x +/- 450, ty +/- 400     (the Via2 LEF definition's Metal3 rect)
  M2 strap     x +/- 420, min(y,ty) - 450 .. max(y,ty) + 450, 0.84 um wide
  via cuts     0.26 um squares on 0.52 um centres

Only the M2 strap and the two via instances are written: the Via1/Via2 LEF
definitions already carry the M1 and M3 landings, so the DEF asks for the same
metal the GDS draws instead of duplicating it at a second place.

One `sub` special net (USE GROUND, no terminals) collects every drop.  The drops
are the substrate-to-VSS tie, so their M3 landing sits across a VSS stripe on
purpose; the DEF net name is not what the G0 checks read, and LVS reads the CDL.

The DEF is edited as text.  The pinned OpenROAD's `odb` Python binding
(`edf00dff...`, openlane2 2.3.10) segfaults on this 158 MB DEF
(`odb.read_def` -> Signal 11), while its DEF reader is the one the flow already
uses for `filled.def`, so the insert is textual and the ODB is written by
OpenROAD from the DEF we just wrote.  Source and output therefore cannot drift.
Run under plain python3 and pass --out-odb to produce both files.
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys

R_M1 = 450
R_M1Y = 390
R_M3 = 450
R_M3Y = 400
R_M2 = 420
STRAP_EXT = 450
CUT = 130
CUT_OFF = 260
VIA1 = "Via1_2X2_0_60_10_60_H_V"
VIA2 = "Via2_2X2_0_60_10_60_V_H"
LAYERS = ("Metal1", "Metal2", "Metal3")


def to_def(nm, upm):
    """nm in GDS dbu (1 nm) -> DEF dbu, round half to even like stream_out.py."""
    num = nm * upm
    q, r = divmod(num, 1000)
    if 2 * r > 1000 or (2 * r == 1000 and q % 2):
        q += 1
    return q


def read_sites(path, upm, die):
    sites = []
    seen = set()
    with open(path) as fh:
        for lineno, line in enumerate(fh, 1):
            if not line.strip() or line.startswith("#"):
                continue
            field = line.strip().split(",")
            if len(field) < 4:
                raise SystemExit(f"{path}:{lineno}: expected name,x,y,ty")
            name, x, y, ty = field[0], int(field[1]), int(field[2]), int(field[3])
            kind = field[4] if len(field) > 4 else "row"
            if name in seen:
                raise SystemExit(f"{path}:{lineno}: duplicate site {name}")
            seen.add(name)
            xd = to_def(x, upm)
            yd = to_def(y, upm)
            tyd = to_def(ty, upm)
            if not (die[0] <= xd <= die[2]
                    and die[1] <= min(yd, tyd) and max(yd, tyd) <= die[3]):
                raise SystemExit(
                    f"{path}:{lineno}: {name} ({x},{y})-({x},{ty}) nm is outside the die")
            if x < R_M3 or y < R_M1Y or ty < R_M1Y:
                raise SystemExit(f"{path}:{lineno}: {name} is too close to the origin")
            sites.append((name, x, y, ty, kind))
    if not sites:
        raise SystemExit(f"{path}: no sites")
    return sites


def def_header(text):
    m = re.search(rb"^UNITS DISTANCE MICRONS (\d+) ;", text, re.M)
    if not m:
        raise SystemExit("DEF: no UNITS DISTANCE MICRONS")
    upm = int(m.group(1))
    d = re.search(rb"^DIEAREA \( (-?\d+) (-?\d+) \) \( (-?\d+) (-?\d+) \) ;", text, re.M)
    if not d:
        raise SystemExit("DEF: no DIEAREA")
    die = tuple(int(v) for v in d.groups())
    if not (die[0] < die[2] and die[1] < die[3]):
        raise SystemExit(f"DEF: bad DIEAREA {die}")
    return upm, die


def site_block(sites, upm):
    # One + ROUTED group per net: the DEF parser accepts repeated NEW items but
    # not a second + ROUTED inside the same special net.
    out = ["- sub + USE GROUND"]
    for idx, (name, x, y, ty, kind) in enumerate(sites):
        xd = to_def(x, upm)
        lo = to_def(min(y, ty) - STRAP_EXT, upm)
        hi = to_def(max(y, ty) + STRAP_EXT, upm)
        yd = to_def(y, upm)
        tyd = to_def(ty, upm)
        lead = "  + ROUTED" if idx == 0 else "    NEW"
        out.append(f"{lead} Metal2 840 ( {xd} {lo} ) ( {xd} {hi} )")
        # The via entry needs its width token, even when it is 0: without it the
        # DEF parser stops at the point with "on token (".
        out.append(f"    NEW Metal1 0 ( {xd} {yd} ) {VIA1}")
        out.append(f"    NEW Metal2 0 ( {xd} {tyd} ) {VIA2}")
    out.append(" ;")
    return "\n".join(out) + "\n"


def check_lef(lef, names):
    with open(lef) as fh:
        text = fh.read()
    for name in names:
        if not re.search(r"^\s*VIA\s+%s\s" % re.escape(name), text, re.M):
            raise SystemExit(f"{lef}: VIA {name} is not defined")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--def", dest="def_", required=True, help="pre-ECO filled DEF")
    ap.add_argument("--lef", required=True, help="LEF that defines the 2x2 vias")
    ap.add_argument("--sites", required=True, help="eco_sites.csv from find_eco_sites.py")
    ap.add_argument("--out-def", required=True)
    ap.add_argument("--out-odb", default=None, help="write the ODB with OpenROAD")
    ap.add_argument("--report", default=None)
    ap.add_argument("--net", default="sub", help="special net that collects the drops")
    args = ap.parse_args()

    check_lef(args.lef, (VIA1, VIA2))

    with open(args.def_, "rb") as fh:
        data = fh.read()
    upm, die = def_header(data)
    sites = read_sites(args.sites, upm, die)

    if re.search(rb"^\s*-\s+%s\b" % re.escape(args.net.encode()), data, re.M):
        raise SystemExit(f"{args.def_}: net {args.net} already exists")
    head = re.search(rb"^SPECIALNETS\s+(\d+)\s*;", data, re.M)
    if not head:
        raise SystemExit(f"{args.def_}: no SPECIALNETS section")
    end = data.find(b"\nEND SPECIALNETS")
    if end < 0:
        raise SystemExit(f"{args.def_}: no END SPECIALNETS")

    count = int(head.group(1)) + 1
    block = site_block(sites, upm).encode()
    if args.net != "sub":
        block = block.replace(b"- sub ", b"- %s " % args.net.encode(), 1)
    patched = (data[:head.start()]
               + b"SPECIALNETS %d ;" % count
               + data[head.end():end + 1]
               + block
               + data[end + 1:])

    if not os.path.isdir(os.path.dirname(os.path.abspath(args.out_def)) or "."):
        raise SystemExit(f"{args.out_def}: directory does not exist")
    with open(args.out_def, "wb") as fh:
        fh.write(patched)

    if args.out_odb:
        tcl = "\n".join([
            "read_lef %s" % os.path.abspath(args.lef),
            "read_def %s" % os.path.abspath(args.out_def),
            "set block [ord::get_db_block]",
            "set n [$block findNet %s]" % args.net,
            'if {$n eq "NULL"} { puts "NET_MISSING %s"; exit 3 }' % args.net,
            'puts "NET [$n getName] special=[$n isSpecial] swires=[llength [$n getSWires]]"',
            "set boxes 0",
            "foreach sw [$n getSWires] { incr boxes [llength [$sw getWires]] }",
            'puts "SBOXES $boxes"',
            "write_db %s" % os.path.abspath(args.out_odb),
            "",
        ])
        proc = subprocess.run(["openroad", "-no_init", "-exit"],
                              input=tcl.encode(), capture_output=True)
        tail = proc.stdout.decode(errors="replace").strip().splitlines()
        for line in tail[-4:]:
            print(line, flush=True)
        if proc.returncode != 0 or not os.path.exists(args.out_odb):
            sys.stderr.write(proc.stderr.decode(errors="replace")[-2000:])
            raise SystemExit(f"openroad did not write {args.out_odb} ({proc.returncode})")

    lines = [
        f"sites          {len(sites)}",
        f"kinds          " + " ".join(f"{k}={sum(1 for s in sites if s[4] == k)}"
                                     for k in sorted({s[4] for s in sites})),
        f"net            {args.net} (USE GROUND, no terminals)",
        f"def_units      {upm} dbu/um",
        f"die            {die[0]} {die[1]} {die[2]} {die[3]} (DEF dbu)",
        f"vias           {VIA1} / {VIA2}",
        f"m1_landing     900 x 780 nm",
        f"m3_landing     900 x 800 nm",
        f"m2_strap       {2*R_M2} nm wide, +{STRAP_EXT} nm past each via centre",
        f"cuts           {CUT*2} nm squares, 0.52 um centres",
        f"in_def         {args.def_} ({os.path.getsize(args.def_)} bytes)",
        f"in_sites       {args.sites}",
        f"out_def        {args.out_def} ({len(patched)} bytes)",
        f"def_sha256     {hashlib.sha256(patched).hexdigest()}",
    ]
    if args.out_odb:
        lines.append(f"out_odb        {args.out_odb} ({os.path.getsize(args.out_odb)} bytes)")
    text = "\n".join(lines)
    if args.report:
        with open(args.report, "w") as fh:
            fh.write(text + "\n")
    print(text, flush=True)


if __name__ == "__main__":
    main()
