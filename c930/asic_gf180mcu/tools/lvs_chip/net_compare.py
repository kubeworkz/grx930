#!/usr/bin/env python3
"""Do the routed database and the schematic netlist connect the same pins? Answer it directly.

The deck's answer for the die is its netter plus `align`, and on this design that has not
returned: `tiling` reached the comparison banner in 13 min and then sat in the netter for 9 h
with one core busy and 4.5 GiB resident, and `deep` did the same for the 30 min it was given.
This script is the check that does not need a netter. It reads the two netlists that already
exist -- the DEF the flow routed, and the CDL the deck is given as schematic -- and compares
their connectivity as a *partition of pins*, which is what a flat LVS comparison is once the
cells have been proven (build/lvs_chip_cell_check.sh: 34 of 34 cells MATCH against the library
CDL, so nothing inside a cell is in question here).

Two properties make this a real check rather than a restatement of one file:

  * the two files name nothing alike. The DEF's nets are `_00000_`, `_00001_[0]`; the CDL's are
    `_02056_` and `u_cpu.u_riscv_core_pipe_alu_result_ex_mem.o_pipe_out[0]`, renamed by
    tools/lvs_chip/mk_chip_cdl.py. Instance names differ by SPICE's mandatory `X`. So the
    comparison cannot pass by comparing strings -- it passes only if the same pins are grouped
    the same way, which is connectivity.
  * it is the same pin universe on both sides. Every instance pin is taken from the cell's own
    port list in the CDL, and a pin the DEF connects but the cell does not declare (or the
    reverse) is a finding, printed.

What it does not cover, said plainly: device geometry inside the cells (that is the cell run),
and power/substrate connectivity (the DEF's SPECIALNETS wildcard the wells, the CDL binds
VNW/VPW/SUB, and the deck's `connect_global` is what decides substrate; that is checked here
only for agreement, not netted).

    python3 tools/lvs_chip/net_compare.py --def build/grx930_test_chip.def \\
                                          --cdl build/lvs_chip/grx930_test_chip.cdl \\
                                          [--top grx930_test_chip] [--json OUT.json] [--show 10]

Exit status: 0 the partitions match, 1 they do not (the differences are printed), 2 could not
run (a file is missing, a section is absent, a net has a pin list this parser cannot read).
"""

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict

# The wells are not in the DEF's NETS; they are tapped, not routed. Listed so the power report can
# say that instead of counting them as lost pins.
WELL_PINS = {"VNW", "VPW", "VBP", "VBN"}
POWER_PIN_NET = {"VDD": "VDD", "VNW": "VNW", "VPW": "SUB", "VSS": "VSS", "SUB": "SUB"}

PIN_RE = re.compile(r"\(\s*(\S+)\s+(\S+)\s*\)")


def norm_inst(name):
    """SPICE instance names must start with X; the DEF's do not. One mapping, applied once."""
    return name[1:] if name.startswith("X") and len(name) > 1 else name


def read_def_components(path):
    """{inst: master} from COMPONENTS, and the port list of PINS."""
    comps, ports = {}, {}
    section = None
    for line in open(path, errors="replace"):
        text = line.strip()
        if text.startswith("COMPONENTS"):
            section = "comp"
            continue
        if text.startswith("END COMPONENTS"):
            section = None
            continue
        if text.startswith("PINS"):
            section = "pins"
            continue
        if text.startswith("END PINS"):
            section = None
            continue
        if text.startswith("NETS") or text.startswith("SPECIALNETS") or text.startswith("END "):
            section = None
            continue
        if section == "comp" and text.startswith("- "):
            parts = text[2:].split()
            if len(parts) >= 2:
                comps[parts[0]] = parts[1]
        elif section == "pins" and text.startswith("- "):
            m = re.match(r"- (\S+) \+ NET (\S+)", text)
            if m:
                ports[m.group(1)] = m.group(2)
    return comps, ports


def read_def_nets(path):
    """({net: [(inst, pin)]}, {power net: wildcard pin names}) from NETS and SPECIALNETS.

    A DEF net is a `- name ( i p ) ...` line whose pin list *wraps*: OpenROAD this long-bus DEF
    continues it on following lines that start with `(`, and only then does `+ USE SIGNAL ;`
    end the statement. Read only the `- ` line and 43,869 of the 53,745 instances lose pins --
    which looks exactly like a design defect, and was one of this script's first results.

    Geometry is the opposite trap: `+ ROUTED`, `NEW` and the `( x y )` points after them are also
    parenthesised pairs. So a pin list ends at the first line that is neither `- ` nor starts
    with `(`, and main() still counts every instance's pins against the ports its cell declares
    rather than trusting this parser.
    """
    nets, special = {}, {}
    section, current, in_pins = None, None, False
    for line in open(path, errors="replace"):
        text = line.strip()
        if text.startswith("NETS"):
            section, current, in_pins = "nets", None, False
            continue
        if text.startswith("SPECIALNETS"):
            section, current, in_pins = "special", None, False
            continue
        if text.startswith("END NETS") or text.startswith("END SPECIALNETS"):
            section, current, in_pins = None, None, False
            continue
        if section is None:
            continue
        if text.startswith("- "):
            m = re.match(r"- (\S+)", text)
            current = m.group(1)
            in_pins = True
            pins = PIN_RE.findall(text.split("+")[0])
            if section == "nets":
                nets[current] = [(i, p.upper()) for i, p in pins]
            else:
                special[current] = [p.upper() for i, p in pins if i == "*"]
            continue
        if in_pins and current is not None and text.startswith("("):
            pins = PIN_RE.findall(text.split("+")[0])
            if section == "nets":
                nets[current].extend((i, p.upper()) for i, p in pins)
            else:
                special[current].extend(p.upper() for i, p in pins if i == "*")
            continue
        in_pins = False
    return nets, special


def read_cdl(path):
    """(top name, top ports, {cell: [pins]}, [(cell, inst, {pin: net})]) from a flat CDL.

    The chip CDL puts the top subcircuit first and appends the library cells after it, so the
    declarations are collected before any instance is resolved -- resolving in one pass would
    read every instance against a library that has not been read yet.
    """
    cells, raw_insts = {}, []
    top, top_ports, top_ports_raw = None, [], []
    pending = ""
    for raw in open(path, errors="replace"):
        text = raw.strip()
        if not text or text.startswith("*"):
            continue
        if text.startswith("+") and pending:
            # A wrapped instance line: SPICE continues with `+` and the cell name is still last.
            pending = pending + " " + text[1:].strip()
            if not pending.endswith("\\"):
                raw_insts.append(pending)
                pending = ""
            continue
        low = text.lower()
        if low.startswith(".subckt"):
            parts = text.split()
            name, pins = parts[1], [p.upper() for p in parts[2:] if not p.startswith("$")]
            cells[name] = pins
            if top is None:
                top, top_ports = name, pins
                # As declared: the net a top port sits on is spelled the way the port is, and that
                # spelling has to match the DEF's net name, which is lower case.
                top_ports_raw = [p for p in parts[2:] if not p.startswith("$")]
            continue
        if low.startswith(".ends"):
            continue
        if text.startswith(("X", "x")):
            if text.endswith("\\"):
                pending = text[:-1]
            else:
                raw_insts.append(text)
    if top is None:
        sys.exit(f"net_compare: CANNOT-RUN no .SUBCKT in {path}")

    insts = []
    for text in raw_insts:
        parts = text.split()
        cell = parts[-1]
        nets = parts[1:-1]
        pins = cells.get(cell)
        if pins is None:
            sys.exit(f"net_compare: CANNOT-RUN instance {parts[0]} uses {cell}, "
                     f"which the CDL does not declare")
        if len(nets) != len(pins):
            sys.exit(f"net_compare: CANNOT-RUN instance {parts[0]} of {cell} lists "
                     f"{len(nets)} nets, its subcircuit declares {len(pins)} pins")
        insts.append((cell, norm_inst(parts[0]), dict(zip(pins, nets))))
    return top, top_ports, top_ports_raw, cells, insts


def partition(pins_by_net, ports):
    """{net: frozenset of (inst, pin)} for the signal pins, plus each port as a `PORT` pin.

    Ports are added on both sides under their own names: a port is the one thing in this
    comparison that must survive by name, and everything else is free to be renamed.
    """
    parts = defaultdict(set)
    for net, pins in pins_by_net.items():
        for inst, pin in pins:
            if pin in POWER_PIN_NET:
                continue
            if inst == "PIN":
                inst = "PORT"
            parts[net].add((inst, pin))
    for port, net in ports.items():
        # The port's own name is the one thing here that must survive by name, and SPICE and DEF
        # disagree about its case, so it is compared in upper case like every other pin.
        parts[net].add(("PORT", port.upper()))
    return {net: frozenset(pins) for net, pins in parts.items()}


def describe(part, limit=3):
    pins = sorted(part)
    shown = ", ".join(f"{i}.{p}" for i, p in pins[:limit])
    more = "" if len(pins) <= limit else f", +{len(pins) - limit}"
    return f"{len(pins)} pins: {shown}{more}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_path", required=True)
    ap.add_argument("--cdl", dest="cdl_path", required=True)
    ap.add_argument("--top", default=None, help="top cell name (default: the CDL's first .SUBCKT)")
    ap.add_argument("--json", dest="json_path", default=None)
    ap.add_argument("--show", type=int, default=10, help="differences to print (default 10)")
    args = ap.parse_args()

    for path in (args.def_path, args.cdl_path):
        if not os.path.exists(path):
            sys.exit(f"net_compare: CANNOT-RUN no {path}")

    comps, def_ports = read_def_components(args.def_path)
    def_nets, special = read_def_nets(args.def_path)
    top, cdl_ports, cdl_ports_raw, cells, cdl_insts = read_cdl(args.cdl_path)
    if args.top and args.top != top:
        sys.exit(f"net_compare: CANNOT-RUN the CDL's top subcircuit is {top}, not {args.top}")
    if not comps or not def_nets or not cdl_insts:
        sys.exit("net_compare: CANNOT-RUN an empty components, nets or instance section")

    print(f"== inputs: {os.path.basename(args.def_path)} {os.path.getsize(args.def_path):,} B, "
          f"{os.path.basename(args.cdl_path)} {os.path.getsize(args.cdl_path):,} B")
    print(f"   top {top}: DEF {len(comps)} components / {len(def_nets)} nets / {len(def_ports)} ports; "
          f"CDL {len(cdl_insts)} instances / {len(cells)} subcircuits / {len(cdl_ports)} ports")

    # 1. The same instances, the same cells. A cell name that differs is a different library, and
    #    every partition below would be comparing a different design.
    empty = set(comps) & {i for c, i, _ in cdl_insts if not c}
    def_cells = Counter(m.split("__")[-1] for m in comps.values())
    cdl_cells = Counter(c.split("__")[-1] for c, _, _ in cdl_insts)
    problems = []
    if set(comps) != {i for _, i, _ in cdl_insts}:
        only_def = sorted(set(comps) - {i for _, i, _ in cdl_insts})
        only_cdl = sorted({i for _, i, _ in cdl_insts} - set(comps))
        problems.append(f"instance sets differ: {len(comps)} in the DEF, {len(cdl_insts)} in the CDL "
                        f"(DEF only {len(only_def)}: {', '.join(only_def[:3])}; "
                        f"CDL only {len(only_cdl)}: {', '.join(only_cdl[:3])})")
    if def_cells != cdl_cells:
        diff = {k: (def_cells.get(k, 0), cdl_cells.get(k, 0))
                for k in set(def_cells) | set(cdl_cells) if def_cells.get(k, 0) != cdl_cells.get(k, 0)}
        problems.append(f"cell populations differ: {diff}")
    print(f"   instances: {'same set' if not problems else 'DIFFERENT'}; "
          f"cells: {len(def_cells)} kinds, {sum(def_cells.values())} placements")

    # 2. The same pins on the same nets. This is the comparison.
    #
    # The DEF writes a top-level port as a pin named `PIN` on the port's net; the CDL has no such
    # entry, so the port is carried across as (`PORT`, name) on both sides.
    def_parts = partition({net: [(inst, pin) for inst, pin in pins] for net, pins in def_nets.items()},
                          {port: port for port in def_ports})
    cdl_by_net = defaultdict(list)
    for cell, inst, conn in cdl_insts:
        for pin, net in conn.items():
            cdl_by_net[net].append((inst, pin))
    cdl_parts = partition(cdl_by_net, {port: port for port in cdl_ports_raw})

    # A net is described by the pins on it, never by its name. Two nets in the same file can carry
    # the same pin set only if they are parallel, so counts are compared as a multiset.
    def_sig = Counter(frozenset(p) for p in def_parts.values())
    cdl_sig = Counter(frozenset(p) for p in cdl_parts.values())
    only_def = def_sig - cdl_sig
    only_cdl = cdl_sig - def_sig
    def_pins = sum(len(p) for p in def_parts.values())
    cdl_pins = sum(len(p) for p in cdl_parts.values())

    print(f"== signal partition: DEF {len(def_parts)} nets / {def_pins} pins; "
          f"CDL {len(cdl_parts)} nets / {cdl_pins} pins")

    # 2b. Every instance's pins are in the comparison. A truncated pin list would make the two
    #     partitions differ for the wrong reason, so the DEF's pins are counted against the ports
    #     the cell declares -- the same list the CDL instance was filled from.
    declared = {inst: {pin for pin in cells[master] if pin not in POWER_PIN_NET}
                for inst, master in comps.items() if master in cells}
    seen = defaultdict(set)
    for pins in def_nets.values():
        for inst, pin in pins:
            if pin not in POWER_PIN_NET:
                seen[inst].add(pin)
    short = {i: sorted(declared[i] - seen.get(i, set())) for i in declared
             if declared[i] - seen.get(i, set())}
    extra = {i: sorted(seen[i] - declared[i]) for i in declared
             if i in seen and seen[i] - declared[i]}
    print(f"   pins per instance: {len(declared) - len(short)} of {len(declared)} complete"
          + (f"; {len(short)} short, e.g. {list(short.items())[:2]}" if short else "")
          + (f"; {len(extra)} with undeclared pins, e.g. {list(extra.items())[:2]}" if extra else ""))
    if short:
        problems.append(f"{len(short)} instances are connected on fewer pins than their cell declares, "
                        f"e.g. {list(short.items())[:2]}")
    if extra:
        problems.append(f"{len(extra)} instances carry pins their cell does not declare, "
                        f"e.g. {list(extra.items())[:2]}")
    net_mismatch = len(only_def) + len(only_cdl)
    if net_mismatch:
        problems.append(f"{net_mismatch} net(s) have no counterpart: "
                        f"{len(only_def)} only in the DEF, {len(only_cdl)} only in the CDL")
        for sig, count in list(only_def.items())[:args.show]:
            print(f"   DEF only x{count}: {describe(sig)}")
        for sig, count in list(only_cdl.items())[:args.show]:
            print(f"   CDL only x{count}: {describe(sig)}")

    # 3. Power and wells: agreement, not netting. The DEF taps VDD/VSS by SPECIALNET and leaves the
    #    wells unrouted; the CDL binds VNW to its own net and VPW to SUB. The deck's connect_global
    #    is what turns those into rails, so nothing here nets them -- it only checks that each side
    #    says what it is supposed to say.
    #
    #    `- VDD ( * VDD ) + USE POWER` is a wildcard: it connects the VDD pin of *every* instance,
    #    so one special net covers all 53,745 of them.
    wild = {net: pins for net, pins in special.items() if pins}
    cdl_power = Counter()
    for _, inst, conn in cdl_insts:
        for pin, net in conn.items():
            if pin in POWER_PIN_NET:
                cdl_power[f"{pin}->{net}"] += 1
    print(f"== power: DEF SPECIALNETS {sorted(special)} (wildcards {wild}); "
          f"CDL binds {dict(sorted(cdl_power.items()))}")
    if empty:
        problems.append(f"{len(empty)} DEF components have no cell name")
    for net, pins in wild.items():
        print(f"   {net}: every instance's {'/'.join(sorted(set(pins)))} pin, {len(comps)} instances")
    missing_wild = sorted({"VDD", "VSS"} - set(wild))
    if missing_wild:
        problems.append(f"the DEF has no wildcard for {missing_wild}, so its rails say nothing "
                        f"about the cells' power pins")
    wells = {pin for pin in WELL_PINS if pin not in {p for pins in wild.values() for p in pins}}
    if wells:
        print(f"   wells {sorted(wells)}: unrouted in the DEF (tapped), bound by the CDL and by the "
              f"deck's connect_global")
    if cdl_power.get("VDD->VDD", 0) != len(cdl_insts) or cdl_power.get("VSS->VSS", 0) != len(cdl_insts):
        problems.append(f"the CDL does not bind VDD/VSS on every instance: {dict(cdl_power)}")

    ok = not problems
    verdict = "MATCH" if ok else "MISMATCH"
    print(f"NET-COMPARE: {verdict} the routed database and the schematic group the same pins"
          if ok else f"NET-COMPARE: MISMATCH")
    for p in problems:
        print(f"   - {p}")

    if args.json_path:
        report = {
            "verdict": verdict,
            "inputs": {os.path.basename(args.def_path): os.path.getsize(args.def_path),
                       os.path.basename(args.cdl_path): os.path.getsize(args.cdl_path)},
            "top": top,
            "def": {"components": len(comps), "nets": len(def_nets), "ports": len(def_ports),
                    "signal_nets": len(def_parts), "signal_pins": def_pins,
                    "power_specials": {k: sorted(v) for k, v in special.items()}},
            "cdl": {"instances": len(cdl_insts), "subcircuits": len(cells),
                    "ports": len(cdl_ports), "signal_nets": len(cdl_parts),
                    "signal_pins": cdl_pins,
                    "power_binding": dict(sorted(cdl_power.items()))},
            "unmatched": {"def_only": len(only_def), "cdl_only": len(only_cdl),
                          "examples": [describe(s) for s in list(only_def)[:20]] +
                                      [describe(s) for s in list(only_cdl)[:20]]},
            "problems": problems,
        }
        with open(args.json_path, "w", encoding="utf-8") as fh:
            json.dump(report, fh, indent=2, sort_keys=True)
            fh.write("\n")
        print(f"   report: {args.json_path}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
