#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Derive the die's layer map by comparing the same cells in two files.

The PDK library GDS uses the documented numbering (comp 22/0, poly2 30/0, contact 33/0,
metal1 34/0 with labels on 34/10, nwell 21/0 + 21/10, and so on). The die's stream does not.
Both files contain the *same* standard cells, so per-cell shape counts and areas give the
correspondence directly -- one cell's comp count is not another cell's poly count.
"""

import sys
from collections import defaultdict

import klayout.db as db

LIB = "/work/c930/asic_gf180mcu/build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds"
DIE = "/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"
CELLS = sys.argv[1:] or ["gf180mcu_fd_sc_mcu7t5v0__clkinv_1",
                         "gf180mcu_fd_sc_mcu7t5v0__mux2_1",
                         "gf180mcu_fd_sc_mcu7t5v0__nand2_1"]


def stats(path):
    ly = db.Layout()
    ly.read(path)
    by_cell = {}
    for name in CELLS:
        cell = ly.cell(name)
        if cell is None:
            continue
        per = defaultdict(lambda: [0, 0, 0.0])
        for li in ly.layer_indexes():
            info = ly.get_info(li)
            for sh in cell.shapes(li).each():
                key = (info.layer, info.datatype)
                per[key][0] += 1
                if sh.is_text():
                    per[key][1] += 1
                    per[key][2] += 0.0
                else:
                    area = sh.box.width() * sh.box.height() if sh.is_box() else sh.polygon.area()
                    per[key][2] += area * ly.dbu * ly.dbu
        by_cell[name] = per
    return by_cell


for label, path in (("PDK library", LIB), ("die", DIE)):
    print(f"===== {label}: {path.split('/')[-1]}")
    for cell, per in stats(path).items():
        items = ", ".join(
            f"{k[0]}/{k[1]}: n={v[0]} txt={v[1]} area={v[2]:.3f}"
            for k, v in sorted(per.items(), key=lambda kv: -kv[1][0])
        )
        print(f"  {cell}: {items}")
    print()
