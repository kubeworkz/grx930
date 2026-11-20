#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""DEF-side facts for the Stage 5 ECO site finder, read through OpenDB.

This is the half of `find_eco_sites.py` that must run inside OpenROAD, because the `odb` module
exists only in the `openroad -python` interpreter. It preflights that import explicitly and
refuses to guess: a plain python3 run has no OpenDB and no business reading a DEF as text.

It returns, as JSON, everything the finder needs from the database:

  * the Metal3 special-net stripe boxes of VSS and VDD (dbSWire geometry, in DEF dbu);
  * the origin of every `*__filltie` instance, the substrate taps;
  * the height of the site each placement row sits on, so the caller knows the row pitch from the
    database instead of guessing it from the tap spacing;
  * the DEF database units, so the caller converts to GDS nanometres once.

    openroad -python tools/lvs_chip/read_def_odb.py --lef cells.lef --def filled.def --out def.json

`find_eco_sites.py` invokes exactly that command; the JSON is a private hand-off, not an input
format anyone should edit.
"""

import argparse
import json
import sys


def main():
    ap = argparse.ArgumentParser(description="DEF-side facts through OpenDB (openroad -python).")
    ap.add_argument("--lef", required=True, help="LEF with the DEF's layers and masters")
    ap.add_argument("--def", dest="def_path", required=True, help="filled DEF")
    ap.add_argument("--out", required=True, help="JSON hand-off for find_eco_sites.py")
    args = ap.parse_args()

    try:
        import odb
    except ImportError:
        sys.exit("read_def_odb: CANNOT-RUN `import odb` failed; run this under `openroad -python`")

    db = odb.dbDatabase.create()
    odb.read_lef(db, args.lef)
    odb.read_def(db.getTech(), args.def_path)
    chip = db.getChip()
    block = chip.getBlock() if chip is not None else None
    if block is None:
        sys.exit(f"read_def_odb: CANNOT-RUN {args.def_path} produced no block")
    units = block.getDefUnits()

    def m3_stripes(net_name):
        """Metal3 wire boxes of one net, straight from its dbSWires."""
        nets = [n for n in block.getNets() if n.getName() == net_name]
        if not nets:
            return []
        boxes = []
        for swire in nets[0].getSWires():
            for w in swire.getWires():
                layer = w.getTechLayer()
                if layer is None or layer.getName() != "Metal3":
                    continue
                # dbSBox accessors are in DEF dbu already; getBox() wants a block+units pair and
                # has crashed on small synthetic DEFs, so read the stored coordinates directly.
                boxes.append([w.xMin(), w.yMin(), w.xMax(), w.yMax()])
        return boxes

    # ROWS are the placement rows themselves; their sites carry the standard-cell row height.
    row_heights = set()
    for row in block.getRows():
        site = row.getSite()
        if site is not None:
            row_heights.add(site.getHeight())

    fillties = []
    for inst in block.getInsts():
        master = inst.getMaster()
        if master is not None and "__filltie" in master.getName():
            loc = inst.getLocation()
            # The binding returns Point or [x, y] depending on the OpenDB build.
            fillties.append([loc.x(), loc.y()] if hasattr(loc, "x") else [loc[0], loc[1]])

    data = {
        "reader": "OpenDB",
        "odb_module": getattr(odb, "__file__", "odb"),
        "def_units": units,
        "def": args.def_path,
        "lef": args.lef,
        "vss_m3": m3_stripes("VSS"),
        "vdd_m3": m3_stripes("VDD"),
        "fillties": fillties,
        "row_count": len(block.getRows()),
        "row_heights": sorted(row_heights),
    }
    with open(args.out, "w") as fh:
        json.dump(data, fh)
    print(f"READ_DEF_ODB units={units} vss_m3={len(data['vss_m3'])} "
          f"vdd_m3={len(data['vdd_m3'])} fillties={len(fillties)} "
          f"rows={data['row_count']} row_heights={data['row_heights']}", flush=True)
    return 0


if __name__ == "__main__":
    main()
