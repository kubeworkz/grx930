#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""mismatch_cell_types.py -- which standard-cell types do the mismatched device pairs sit in?

`lvsdb_mismatch_cells.rb` gives the mismatched devices grouped by *instance* (`_68736_`). The DEF
says which cell type each instance is. Joining the two turns 95 scattered instances into the
handful of cell types whose internal nets need labelling, which is what decides whether the
labelling job is three cells or forty.

    python3 probe/mismatch_cell_types.py \
        --def build/grx930_test_chip.def \
        --cells evidence_lvs/filled-rect-stitched-b12300/mismatch_cells.txt
"""
import argparse
import collections
import re


def parse_components(path):
    """instance name -> cell type, from the DEF COMPONENTS section."""
    inst = {}
    in_components = False
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            if line.startswith("COMPONENTS"):
                in_components = True
                continue
            if not in_components:
                continue
            if line.startswith("END COMPONENTS"):
                break
            # - name cell + ...  (placement follows the cell name)
            parts = line.split()
            if len(parts) >= 3 and parts[0] == "-":
                inst[parts[1]] = parts[2]
    return inst


def parse_probe(path):
    """instance -> mismatched device count, from the probe's INSTANCES block."""
    counts = {}
    inside = False
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            if line.startswith("INSTANCES "):
                inside = True
                continue
            if inside:
                if line.startswith("NET PAIRS"):
                    break
                m = re.match(r"^\s+(\S+)\s+(\d+) devices\s*$", line)
                if m:
                    counts[m.group(1)] = int(m.group(2))
    return counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def-file", required=True)
    ap.add_argument("--cells", required=True)
    args = ap.parse_args()

    inst = parse_components(args.def_file)
    counts = parse_probe(args.cells)
    print(f"DEF instances {len(inst)}; mismatched instances {len(counts)}")

    by_type = collections.Counter()
    devices = collections.Counter()
    missing = []
    for name, devs in counts.items():
        cell = inst.get(name)
        if cell is None:
            missing.append(name)
            continue
        by_type[cell] += 1
        devices[cell] += devs
    if missing:
        print(f"NOT-IN-DEF {len(missing)}: " + ", ".join(sorted(missing)[:10]))

    print(f"CELL TYPES {len(by_type)}")
    for cell, n in by_type.most_common():
        print(f"  {cell:52s} {n:4d} instances {devices[cell]:4d} devices")


if __name__ == "__main__":
    main()
