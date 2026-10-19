#!/usr/bin/env python3
"""Turn the routed Verilog into the chip CDL the LVS deck reads.

Two things the flat netlist needs done to it:

  * **Names.** Verilog escaped identifiers here are written as `\\name [3]`, which is `name`,
    bit 3 of a bus -- SPICE has no such token, so every net is renamed mechanically and
    consistently (`name[3]`), and a collision check runs before anything is written. Net names
    are not connectivity, so renaming cannot change the answer; collisions could, which is why
    they stop the generator.
  * **Power.** The netlist carries no power connections at all (no `supply0/1`), while the deck
    extracts each cell with its VNW/VPW bulks: VDD and VSS come from the PDK cell definition,
    VNW is the nwell net the deck keeps separate, and VPW is bound to `SUB` because that is what
    the deck makes of the p-substrate (see the single-cell probe: the extracted netlist declared
    pins VSS VDD I ZN SUB).

The cell subcircuits are appended unchanged from the PDK library CDL, so the comparison is
device-level inside the cells and connectivity-level between them.

Exit status: 0 written, 2 refused (a parse or name check failed).
"""

import os
import re
import sys

ROOT = "/work/c930/asic_gf180mcu"
ROUTED = f"{ROOT}/build/grx930_test_chip_routed.v"
LIBCDL = f"{ROOT}/gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/cdl/gf180mcu_fd_sc_mcu7t5v0.cdl"
OUT = f"{ROOT}/build/lvs_chip/grx930_test_chip.cdl"

POWER = {"VDD": "VDD", "VSS": "VSS", "VNW": "VNW", "VPW": "SUB"}


def sanitize(name):
    """One SPICE-safe token, applied identically to declarations and connections."""
    name = name.strip()
    if name.startswith("\\"):
        name = name[1:]
    name = name.replace(" ", "")
    return name


def lib_subckts(path):
    """{cell: [pins]} for every .SUBCKT in the library CDL."""
    out, current, pins = {}, None, []
    for line in open(path, errors="replace"):
        text = line.strip()
        if text.lower().startswith(".subckt"):
            parts = text.split()
            current = parts[1]
            pins = [p.upper() for p in parts[2:]]
            out[current] = pins
        elif text.lower().startswith(".ends"):
            current = None
    return out


def parse_instances(path):
    """[(cell, inst, {port: net})] from a flat gate-level netlist."""
    body = open(path, errors="replace").read()
    header = re.search(r"module\s+(\w+)\s*\(([^)]*)\)", body)
    top = header.group(1)
    ports = [sanitize(p) for p in header.group(2).split(",") if p.strip()]
    body = body[header.end():]

    insts = []
    for match in re.finditer(r"\b(gf180mcu_fd_sc_\w+)\s+(\S+)\s*\((.*?)\)\s*;", body, re.S):
        cell, inst, conns = match.group(1), match.group(2), match.group(3)
        pairs = re.findall(r"\.(\w+)\s*\(([^)]*)\)", conns)
        insts.append((cell, inst, {p.upper(): sanitize(n) for p, n in pairs}))
    return top, ports, insts


def main():
    lib = lib_subckts(LIBCDL)
    top, ports, insts = parse_instances(ROUTED)
    # A bus port has to arrive at the deck as its bits: the layout's labels are literal
    # `o_gpio[3]` strings, and the port check compares those strings, not bus semantics.
    used = {n for _, _, c in insts for n in c.values()}
    expanded = []
    for port in ports:
        bits = sorted((n for n in used if re.fullmatch(re.escape(port) + r"\[\d+\]", n)),
                      key=lambda n: int(n[n.index("[") + 1:-1]))
        expanded.extend(bits or [port])
    ports = expanded
    print(f"{os.path.basename(ROUTED)}: top {top}, {len(ports)} ports, {len(insts)} instances")

    cells = sorted({c for c, _, _ in insts})
    missing = [c for c in cells if c not in lib]
    if missing:
        print(f"REFUSED  {len(missing)} cell types not in the library CDL: {missing[:5]}")
        return 2
    print(f"{len(cells)} cell types, all in the library CDL")

    nets = set()
    bad = []
    for cell, inst, conns in insts:
        want = lib[cell]
        for pin in want:
            net = POWER.get(pin) or conns.get(pin)
            if net is None:
                bad.append(f"{cell} {inst} pin {pin} unconnected")
            else:
                nets.add(net)
    if bad:
        print(f"REFUSED  {len(bad)} unconnected pins, e.g. {bad[:3]}")
        return 2

    flat = sorted(nets)
    if len(set(flat)) != len(flat):
        print("REFUSED  duplicate net names after sanitising")
        return 2

    with open(OUT, "w") as fh:
        fh.write(f"* {top}: routed gate-level netlist, cells from the PDK library CDL\n")
        fh.write(f".SUBCKT {top} {' '.join(ports)}\n")
        for cell, inst, conns in insts:
            nets_ordered = [POWER.get(pin) or conns[pin] for pin in lib[cell]]
            fh.write(f"X{inst} {' '.join(nets_ordered)} {cell}\n")
        fh.write(".ENDS\n\n")
        text = open(LIBCDL, errors="replace").read()
        wanted = set(cells)
        keep, writing = [], False
        for line in text.splitlines():
            low = line.strip().lower()
            if low.startswith(".subckt"):
                writing = line.split()[1] in wanted
                if writing:
                    keep.append(line)
                continue
            if writing:
                keep.append(line)
                if low.startswith(".ends"):
                    writing = False
        # every cell must have brought its definition along
        kept = {l.split()[1] for l in keep if l.strip().lower().startswith(".subckt")}
        if kept != wanted:
            print(f"REFUSED  {len(wanted - kept)} cell definitions missing: "
                  f"{sorted(wanted - kept)[:5]}")
            return 2
        fh.write("\n".join(keep) + "\n")

    print(f"wrote {OUT} ({os.path.getsize(OUT)} B): {len(insts)} X instances, "
          f"{len(nets)} nets, {len(kept)} cell definitions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
