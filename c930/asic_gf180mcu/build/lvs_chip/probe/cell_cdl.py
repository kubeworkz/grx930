#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Cut named .SUBCKT blocks out of the library CDL, one file per cell.

`build/lvs_chip/probe/cell_label_lvs.sh` compares one cell at a time and reads its netlist from
`build/lvs_chip/cell_census/<cell>.cdl`. That directory only holds the cell types an earlier run
happened to need; the corrected die's mismatch set names ten more, and the block is already in the
library CDL -- this takes it verbatim, so a cell's device sizes and internal net names are the
library's own, not a re-typing.

  python3 cell_cdl.py --lib <library.cdl> --outdir build/lvs_chip/cell_census \\
      --cells gf180mcu_fd_sc_mcu7t5v0__dffnq_1 ...

Exit status: 0 written, 2 a requested cell is not in the library.
"""

import argparse
import os
import sys


def main():
    ap = argparse.ArgumentParser(description="Extract .SUBCKT blocks from the library CDL.")
    ap.add_argument("--lib", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--cells", nargs="+", required=True)
    args = ap.parse_args()

    wanted = set(args.cells)
    found = {}
    current, buf = None, []
    with open(args.lib, errors="replace") as fh:
        for line in fh:
            low = line.strip().lower()
            if low.startswith(".subckt"):
                current = line.split()[1]
                buf = [line]
            elif current:
                buf.append(line)
                if low.startswith(".ends"):
                    if current in wanted:
                        found[current] = "".join(buf)
                    current = None

    missing = sorted(wanted - set(found))
    if missing:
        print(f"REFUSED  {len(missing)} cell(s) not in {args.lib}: {missing[:5]}", file=sys.stderr)
        return 2

    os.makedirs(args.outdir, exist_ok=True)
    for cell in sorted(found):
        path = os.path.join(args.outdir, f"{cell}.cdl")
        with open(path, "w") as fh:
            fh.write(found[cell])
        print(f"{os.path.basename(path)}  {len(found[cell])} B")
    return 0


if __name__ == "__main__":
    sys.exit(main())
