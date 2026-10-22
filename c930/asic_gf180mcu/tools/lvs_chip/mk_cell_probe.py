#!/usr/bin/env python3
"""Build a one-cell LVS fixture out of the real die: one std cell from the GDS, its PDK CDL.

Why: before spending hours extracting 20 mm^2, check the harness on a *real* cell of the
layout -- the same tech, the same deck switches, the same netlist source -- so that a later
mismatch is about connectivity rather than about a layer or a switch nobody exercised.

    python3 build/lvs_chip/mk_cell_probe.py <cellname> [<cellname> ...]

Writes build/lvs_chip/probe/<cell>.cdl (the .SUBCKT block from the library CDL, unchanged).
No separate GDS is written: the die's own file is the layout, and the deck is told which cell
to extract with `--topcell`. A copied-out cell would read the same geometry through a second
artifact, which is one more thing that could be the one that differs.

Run inside the flow image (needs klayout.db); the paths below are container paths under /work.
"""

import os
import sys

CELLS = sys.argv[1:] or ["gf180mcu_fd_sc_mcu7t5v0__clkinv_1"]

GDS = "/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"
LIB = "/work/c930/asic_gf180mcu/gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/cdl/gf180mcu_fd_sc_mcu7t5v0.cdl"
OUT = "/work/c930/asic_gf180mcu/build/lvs_chip/probe"


def subckt_block(path, name):
    """The .SUBCKT <name> ... .ENDS block, verbatim."""
    lines = open(path, errors="replace").read().splitlines()
    out, inside = [], False
    for line in lines:
        low = line.strip().lower()
        if low.startswith(".subckt"):
            inside = line.split()[1].lower() == name.lower()
            if inside:
                out.append(line)
            continue
        if inside:
            out.append(line)
            if low.startswith(".ends"):
                return out
    return out


def main():
    import klayout.db as db

    os.makedirs(OUT, exist_ok=True)
    ly = db.Layout()
    ly.read(GDS)
    top = ly.top_cell()
    cells = {c.name: c for c in ly.each_cell()}
    print(f"die {top.name}: {ly.cells()} cells, top has {top.child_instances()} instances")
    for name in CELLS:
        cell = cells.get(name)
        if cell is None:
            print(f"MISS  {name}: not a cell in the die")
            continue
        cdl = os.path.join(OUT, f"{name}.cdl")
        with open(cdl, "w") as fh:
            fh.write(f"* {name}, lifted from the PDK library CDL, as the die's own cell\n")
            fh.write("\n".join(subckt_block(LIB, name)) + "\n")
        devices = sum(1 for l in open(cdl) if l[:1] in "Mm")
        print(
            f"{name}: layout cell has {cell.child_instances()} instances, "
            f"cdl {os.path.relpath(cdl, '/work')} has {devices} M devices"
        )


if __name__ == "__main__":
    main()
