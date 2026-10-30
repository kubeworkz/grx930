#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Cut single cells out of the shipped stream-out so the deck can LVS them one at a time.

Why: the chip run is hours long, and most of what it has to prove is not the routing. The
September artifact's standard cells were LEF abstracts -- pin rectangles and a boundary -- so no
deck could have found a transistor in them. The repaired stream has the library's real layouts in
its cells; this cuts a few of those cells out as their own top cell, with their own netlist taken
from the same CDL the chip run compares against, so the deck can answer the cell question in
seconds instead of hours.

    python3 tools/lvs_chip/cell_lvs.py --gds build/lvs_chip/stream_out.gds \\
            --cdl build/lvs_chip/grx930_test_chip.cdl \\
            --cells gf180mcu_fd_sc_mcu7t5v0__clkinv_1,gf180mcu_fd_sc_mcu7t5v0__nand2_1 \\
            --out build/lvs_chip/cell_lvs

Writes <out>/<cell>.gds (that cell as the only top cell) and <out>/<cell>.cdl (that cell's
.SUBCKT..ENDS from the full CDL). Exit status 0 when every requested cell was written, 1 when a
name was not found, 2 on a usage/IO error.
"""

import argparse
import os
import re
import sys

try:
    import klayout.db as db
except ImportError:
    print("cell_lvs: klayout.db is not available (run inside the flow image)", file=sys.stderr)
    sys.exit(2)


def subckt_block(cdl_path, cell):
    """The .SUBCKT <cell> ... .ENDS block, byte for byte, as the library CDL spelled it."""
    out = []
    inside = False
    with open(cdl_path, "r", errors="replace") as fh:
        for line in fh:
            if not inside:
                m = re.match(r"\s*\.SUBCKT\s+(\S+)", line, re.I)
                if m and m.group(1) == cell:
                    inside = True
                    out.append(line)
                continue
            out.append(line)
            if re.match(r"\s*\.ENDS", line, re.I):
                return "".join(out)
    return None


def write_cell_gds(ly, cell, path):
    src = ly.cell(cell)
    if src is None:
        return False
    out = db.Layout()
    out.dbu = ly.dbu
    dst = out.create_cell(cell)
    dst.copy_tree(src)
    out.write(path)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gds", required=True)
    ap.add_argument("--cdl", required=True)
    ap.add_argument("--cells", required=True, help="comma-separated cell names")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    ly = db.Layout()
    ly.read(a.gds)
    os.makedirs(a.out, exist_ok=True)

    bad = 0
    for cell in [c for c in a.cells.split(",") if c.strip()]:
        cell = cell.strip()
        gds_out = os.path.join(a.out, cell + ".gds")
        cdl_out = os.path.join(a.out, cell + ".cdl")
        block = subckt_block(a.cdl, cell)
        if block is None:
            print(f"{cell}: no .SUBCKT in {a.cdl}")
            bad += 1
            continue
        if not write_cell_gds(ly, cell, gds_out):
            print(f"{cell}: not a cell in {a.gds}")
            bad += 1
            continue
        with open(cdl_out, "w") as fh:
            fh.write(block if block.endswith("\n") else block + "\n")
        devices = len([l for l in block.splitlines() if re.match(r"\s*[MmRrCc]", l)])
        print(f"{cell}: {os.path.getsize(gds_out)} B GDS, {devices} device cards in the netlist")

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
