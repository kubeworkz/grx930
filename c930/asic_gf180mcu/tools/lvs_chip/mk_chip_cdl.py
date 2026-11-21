#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Turn the routed Verilog into the chip CDL the LVS deck reads.

Two things the flat netlist needs done to it:

  * **Names.** Verilog escaped identifiers here are written as `\\name [3]`, which is `name`,
    bit 3 of a bus -- SPICE has no such token, so every net is renamed mechanically and
    consistently (`name[3]`), and a collision check runs before anything is written. Net names
    are not connectivity, so renaming cannot change the answer; collisions could, which is why
    they stop the generator.
  * **Power.** The netlist carries no power connections at all (no `supply0/1`), while the deck
    extracts each cell with its VNW/VPW bulks: VDD and VSS come from the PDK cell definition.
    The bulks are tied to those same supplies, and that is a statement about *this die*, not a
    convenience: `rule_decks/substrate_connections.lvs` puts every p-tap on one global `SUB`,
    and the well-tie/fill cells (tools/lvs_chip/fill_def.py) tie the p-taps to the VSS rails, so
    the layout has a single p-side net holding both the NFET bodies and the cell VSS pins. On
    the n-side the taps join each nwell to its VDD rail. A schematic that kept VNW and VPW as
    separate nets could therefore never pair: the die census measured no layout VNW net at all
    (PFET bodies sit on VDD or on untapped, unnamed wells), and its p-side is one net against
    the schematic's two. Mapping VNW->VDD and VPW->VSS reproduces the partition the geometry
    has; it does not hide the untapped wells, which stay unmatched because no schematic net
    exists at their bulk.

The cell subcircuits are appended unchanged from the PDK library CDL, so the comparison is
device-level inside the cells and connectivity-level between them. "Unchanged" is checked, not
assumed: the appended block is hashed and both digests go into the netlist header, so an LVS
answer can be tied to the exact library revision its device sizes came from.

Nothing is skipped. Every statement in the routed netlist has to be a declaration or an
instance of a library cell; a parameter or delay override, a second module, a behavioural
block, or an instance of anything else (an SRAM macro, a black box) stops the generator. A
statement this script quietly dropped would be a device the deck never sees, and that is the
one difference LVS cannot report on its own.

Exit status: 0 written, 2 refused (a parse, name, cell or library check failed).
"""

import argparse
import hashlib
import os
import re
import sys

ROOT = "/work/c930/asic_gf180mcu"
ROUTED = f"{ROOT}/build/grx930_test_chip_routed.v"
LIBCDL = f"{ROOT}/gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/cdl/gf180mcu_fd_sc_mcu7t5v0.cdl"
OUT = f"{ROOT}/build/lvs_chip/grx930_test_chip.cdl"

# Bulk pins follow the supplies, the way the taps tie them on the die. See the module docstring:
# the deck's substrate rule makes the p-side one net, and the nwell taps join VDD.
POWER = {"VDD": "VDD", "VSS": "VSS", "VNW": "VDD", "VPW": "VSS",
         # The pad ring's IO supplies are the same nets: the routed DEF's VDD SPECIALNET carries
         # `( * DVDD )` and VSS carries `( * DVSS )`, so an IO cell's DVDD/DVSS pin is VDD/VSS.
         "DVDD": "VDD", "DVSS": "VSS"}

# Statements that carry no devices and no connectivity.
ALLOWED = {"wire", "reg", "input", "output", "inout", "parameter", "localparam",
           "supply0", "supply1", "tri", "assign", "endmodule", "integer"}

# Statements that would mean this is not a gate-level netlist at all.
BEHAVIOURAL = {"always", "always_ff", "always_comb", "initial", "generate", "genvar",
               "function", "task"}

INST = re.compile(r"([^\s(]+)\s*\((.*)\)\s*$", re.S)


class Refused(Exception):
    """A check failed; main prints the message and exits 2."""


def refuse(message):
    raise Refused(message)


def short(text, width=90):
    return text if len(text) <= width else text[:width - 3] + "..."


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


def parse_instances(path, lib):
    """(top, [ports], [(cell, inst, {port: net})]) from a flat gate-level netlist.

    Every semicolon-terminated statement is classified. Anything that is not a declaration or
    an instance of a cell in `lib` is refused here rather than left for the deck to notice by
    reporting a mismatch, or -- worse -- not notice at all.
    """
    body = open(path, errors="replace").read()
    header = re.search(r"module\s+(\w+)\s*\(([^)]*)\)", body)
    if header is None:
        refuse(f"no `module <top> (<ports>)` header in {os.path.basename(path)}")
    top = header.group(1)
    ports = [sanitize(p) for p in header.group(2).split(",") if p.strip()]
    body = body[header.end():]
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
    body = re.sub(r"//[^\n]*", "", body)

    # A second module can only arrive as a declaration at the start of a line; matching it
    # anywhere would trip over escaped net names such as `\\u_cpu.module_out [3]`.
    ended = False
    for line in body.splitlines():
        text = line.strip()
        if re.match(r"module\b", text):
            refuse("more than one module: the deck reads one flat top")
        if re.match(r"endmodule\b", text):
            ended = True

    insts = []
    chunks = body.split(";")
    for chunk in chunks[:-1]:
        stmt = chunk.strip()
        while stmt.startswith("(*"):            # attributes carry no connectivity
            end = stmt.find("*)")
            if end < 0:
                refuse(f"unterminated attribute: {short(stmt)}")
            stmt = stmt[end + 2:].strip()
        if not stmt:
            continue
        word = stmt.split(None, 1)[0]
        if word == "endmodule":
            ended = True
            continue
        if word in ALLOWED:
            continue
        if word in BEHAVIOURAL:
            refuse(f"`{word}` in a gate-level netlist: the deck can only compare cells")
        if word == "module":
            refuse("more than one module: the deck reads one flat top")
        head = re.match(r"[^\s(]+", stmt).group(0)
        cell = head.lstrip("\\")
        rest = stmt[len(head):].lstrip()
        if rest.startswith("#"):
            refuse(f"{cell}: parameter or delay on an instance. The deck takes device sizes "
                   "from the library CDL, so an override in the netlist has nowhere to go")
        match = INST.match(rest)
        if match is None:
            refuse(f"neither a declaration nor an instance: {short(stmt)}")
        inst = match.group(1).lstrip("\\")
        if cell not in lib:
            refuse(f"{inst}: {cell} is not in the library CDL. It would reach the deck as an "
                   "instance with no definition -- a device LVS cannot see")
        pairs = re.findall(r"\.(\w+)\s*\(([^)]*)\)", match.group(2))
        insts.append((cell, inst, {p.upper(): sanitize(n) for p, n in pairs}))

    tail = chunks[-1].strip()
    if tail.startswith("endmodule"):
        tail = tail[len("endmodule"):].strip()
    if tail:
        refuse(f"trailing text after the last statement: {short(tail)}")
    if not ended:
        refuse("no endmodule: the netlist looks truncated")
    return top, ports, insts


def main():
    ap = argparse.ArgumentParser(
        description="Turn a routed netlist into the chip CDL the LVS deck reads.")
    ap.add_argument("--routed", default=ROUTED,
                    help="routed netlist to convert (default: the canonical one)")
    ap.add_argument("--out", default=OUT,
                    help="CDL to write (default: the chip CDL the deck reads)")
    ap.add_argument("--top", default=None,
                    help="name for the CDL .SUBCKT (default: the netlist's module name); "
                         "use the layout top when the netlist module and the GDS top differ")
    ap.add_argument("--lib", action="append", default=None,
                    help="library CDL to take cell definitions from; repeatable. The default is "
                         "the standard-cell CDL; add the IO CDL when the netlist instantiates pads")
    ap.add_argument("--float-unconnected", action="store_true",
                    help="give a deliberately unconnected pin its own floating net instead of "
                         "refusing. A clock-load cell's Z or an unused pad output has no driver and "
                         "no load; the routed netlist omits it, and a CDL must still name a node. "
                         "Each float is unique, so no two pins are silently joined")
    args = ap.parse_args()
    try:
        return generate(args.routed, args.out, args.top, args.lib, args.float_unconnected)
    except Refused as err:
        print(f"REFUSED  {err}")
        return 2


def generate(routed, out, top_override=None, lib_paths=None, float_unconnected=False):
    if top_override is not None and not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", top_override):
        refuse(f"--top {top_override!r} is not a SPICE subcircuit name")
    lib_paths = lib_paths or [LIBCDL]
    lib = {}
    lib_meta = []
    for path in lib_paths:
        if not os.path.exists(path):
            refuse(f"no library CDL at {path}")
        cells = lib_subckts(path)
        clash = sorted(set(cells) & set(lib))
        if clash:
            refuse(f"{len(clash)} cells defined in more than one library CDL: {clash[:5]}")
        lib.update(cells)
        lib_meta.append((path, hashlib.sha256(open(path, "rb").read()).hexdigest()))
    parsed_top, ports, insts = parse_instances(routed, lib)
    top = top_override or parsed_top
    if top != parsed_top:
        print(f"top: {parsed_top} -> {top} (layout top)")
    # A bus port has to arrive at the deck as its bits: the layout's labels are literal
    # `o_gpio[3]` strings, and the port check compares those strings, not bus semantics.
    used = {n for _, _, c in insts for n in c.values()}
    expanded = []
    for port in ports:
        bits = sorted((n for n in used if re.fullmatch(re.escape(port) + r"\[\d+\]", n)),
                      key=lambda n: int(n[n.index("[") + 1:-1]))
        expanded.extend(bits or [port])
    ports = expanded
    print(f"{os.path.basename(routed)}: top {top}, {len(ports)} ports, {len(insts)} instances")

    cells = sorted({c for c, _, _ in insts})
    print(f"{len(cells)} cell types, all in the library CDL")

    nets = set()
    bad = []
    floated = 0
    for cell, inst, conns in insts:
        want = lib[cell]
        for pin in want:
            net = POWER.get(pin) or conns.get(pin)
            if net is None:
                if float_unconnected:
                    net = sanitize(f"NC_{inst}_{pin}")
                    conns[pin] = net
                    floated += 1
                else:
                    bad.append(f"{cell} {inst} pin {pin} unconnected")
            nets.add(net)
    if bad:
        refuse(f"{len(bad)} unconnected pins, e.g. {bad[:3]}")
    if floated:
        print(f"floated {floated} deliberately unconnected pins on unique nets")

    flat = sorted(nets)
    if len(set(flat)) != len(flat):
        refuse("duplicate net names after sanitising")

    wanted = set(cells)
    keep = []
    for path, _ in lib_meta:
        text = open(path, errors="replace").read()
        writing = False
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
        refuse(f"{len(wanted - kept)} cell definitions missing: {sorted(wanted - kept)[:5]}")

    block = "\n".join(keep) + "\n"
    block_sha = hashlib.sha256(block.encode()).hexdigest()

    with open(out, "w") as fh:
        fh.write(f"* {top}: routed gate-level netlist, cells from the PDK library CDLs\n")
        for path, lib_sha in lib_meta:
            fh.write(f"* library: {os.path.basename(path)} sha256 {lib_sha}\n")
        fh.write(f"* appended: {len(kept)} cell definitions, sha256 {block_sha}\n")
        fh.write(f".SUBCKT {top} {' '.join(ports)}\n")
        for cell, inst, conns in insts:
            nets_ordered = [POWER.get(pin) or conns[pin] for pin in lib[cell]]
            fh.write(f"X{inst} {' '.join(nets_ordered)} {cell}\n")
        fh.write(".ENDS\n\n")
        fh.write(block)

    print(f"wrote {out} ({os.path.getsize(out)} B): {len(insts)} X instances, "
          f"{len(nets)} nets, {len(kept)} cell definitions")
    for path, lib_sha in lib_meta:
        print(f"library CDL {os.path.basename(path)} sha256 {lib_sha}")
    print(f"appended definitions sha256 {block_sha}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
