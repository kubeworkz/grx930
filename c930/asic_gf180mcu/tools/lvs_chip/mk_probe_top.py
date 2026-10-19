#!/usr/bin/env python3
"""A small LVS probe with real geometry: a new top cell containing one std cell from the die.

Why this and not `--topcell <std cell>`: asking the deck for a child cell of a 237-cell GDS
came back with "Total no. of polygons in the design is 0" -- the runset's `source(file, cell)`
selects that cell but leaves it empty. Rather than guess at the runset's read path, this makes
a probe file whose *only* top cell is the probe, so no cell selection is involved: same
geometry, same library cell, same deck.

    python3 build/lvs_chip/mk_probe_top.py <stdlibcell> [<name>]

Writes build/lvs_chip/probe/<name>.gds (in the die layout, probe top added, die top deleted) and
build/lvs_chip/probe/<name>.cdl (probe top instantiating the cell, plus the cell's own .SUBCKT
from the library CDL). Also reports the cell's text labels: hierarchical LVS needs the layout
cell to carry its pin names, and the labels are where they come from.

Run inside the flow image (needs klayout.db); paths below are container paths under /work.
"""

import os
import sys

CELL = sys.argv[1] if len(sys.argv) > 1 else "gf180mcu_fd_sc_mcu7t5v0__clkinv_1"
NAME = sys.argv[2] if len(sys.argv) > 2 else "clkinv_probe"

GDS = "/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"
LIB = "/work/c930/asic_gf180mcu/gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/cdl/gf180mcu_fd_sc_mcu7t5v0.cdl"
OUT = "/work/c930/asic_gf180mcu/build/lvs_chip/probe"


def lib_subckt(cell):
    """(text of the .SUBCKT block, [pins]) for one library cell."""
    lines = open(LIB, errors="replace").read().splitlines()
    out, inside = [], False
    for line in lines:
        low = line.strip().lower()
        if low.startswith(".subckt"):
            inside = line.split()[1].lower() == cell.lower()
            if inside:
                out.append(line)
            continue
        if inside:
            out.append(line)
            if low.startswith(".ends"):
                return "\n".join(out), [p.upper() for p in out[0].split()[2:]]
    raise SystemExit(f"MISS  {cell}: no .SUBCKT in {LIB}")


def main():
    import klayout.db as db

    os.makedirs(OUT, exist_ok=True)
    block, pins = lib_subckt(CELL)
    print(f"{CELL}: pins from the library CDL: {' '.join(pins)}")

    ly = db.Layout()
    ly.read(GDS)
    cell = ly.cell(CELL)
    if cell is None:
        raise SystemExit(f"MISS  {CELL}: not a cell in {GDS}")

    labels = []
    for li in ly.layer_indexes():
        info = ly.get_info(li)
        for sh in cell.shapes(li).each():
            if sh.is_text():
                labels.append((f"{info.layer}/{info.datatype}", sh.text.string))
    print(f"{CELL}: {cell.child_instances()} instances, text labels: {labels}")
    if not labels:
        print("NOTE  the cell carries no labels: a hierarchical comparison cannot tie its pins")

    probe = ly.create_cell(NAME)
    probe.insert(db.CellInstArray(cell.cell_index(), db.Trans()))
    # Keep only the probe and the one library cell it instantiates. Deleting the die top alone
    # is not enough: every cell it instantiated then becomes a top cell of its own (236 of
    # them), and a file with no single top leaves the runset's `source(file)` to pick one.
    keep = {NAME.lower(), CELL.lower()}
    for index in [c.cell_index() for c in ly.each_cell() if c.name.lower() not in keep]:
        ly.delete_cell(index)
    ly.cleanup()
    gds = os.path.join(OUT, f"{NAME}.gds")
    ly.write(gds)

    cdl = os.path.join(OUT, f"{NAME}.cdl")
    with open(cdl, "w") as fh:
        # The probe top's pins are the cell's own ports: the probe is one instance of it.
        fh.write(f".SUBCKT {NAME} {' '.join(pins)}\n")
        fh.write(f"X1 {' '.join(pins)} {CELL}\n")
        fh.write(".ENDS\n")
        fh.write(f"* {CELL}, from the PDK library CDL, unchanged\n")
        fh.write(block + "\n")
    print(
        f"wrote {gds} ({os.path.getsize(gds)} B, {ly.cells()} cells, tops="
        f"{[c.name for c in ly.top_cells()]}) and {cdl} ({os.path.getsize(cdl)} B)"
    )


if __name__ == "__main__":
    main()
