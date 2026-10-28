#!/usr/bin/env python3
"""def_fanout_probe.py -- per-net load counts and drivers, read from a DEF.

Why this exists
---------------

The STA reports only imply where the load is: a slew table says
`_351675_/RN` sees a 21-47 ns transition, not that one buffer drives 2,132
pins. Reading that off the DEF is a single pass and is engine-neutral (the DEF
is the same artefact both OpenROAD builds write), so the answer does not depend
on which engine is installed.

DEF detail that matters here: component, pin and net entries are indented
(`    - <name> ...`), so a check on the raw line (`line.startswith("- ")`)
finds no components and no nets at all -- the section headers (`COMPONENTS
340141 ;`, `NETS 243830 ;`) are the only lines at column zero. This reads the
sections explicitly and strips before matching.

Usage:
    def_fanout_probe.py <file.def> [--net NAME] [--top N] [--rst]

    --net NAME   dump every pin of one net (exact name, then regex fallback)
    --top N      how many nets to list by load count (default 15)
    --rst        list every net whose name matches /rst/i
"""

import argparse
import collections
import re
import sys

FILLER = (
    "gf180mcu_fd_sc_mcu7t5v0__fill",
    "gf180mcu_fd_sc_mcu7t5v0__fillcap",
    "gf180mcu_fd_sc_mcu7t5v0__filltie",
    "gf180mcu_fd_sc_mcu7t5v0__endcap",
    "gf180mcu_fd_sc_mcu7t5v0__antenna",
)
# Pins that can drive a net in this library: std cells (Z/ZN), pads (Y/PAD).
DRIVER_PINS = ("Y", "Z", "ZN", "Q", "QN", "CO", "PAD")


def read_def(path):
    masters = {}
    pins_declared = []
    nets = []           # [(name, [(inst, pin), ...])]
    specials = []
    mode = None
    net = None
    cur = []
    hdr = re.compile(r"^(COMPONENTS|NETS|SPECIALNETS|PINS)\s+(\d+)\s*;")
    for line in open(path, errors="replace"):
        t = line.strip()
        m = hdr.match(t)
        if m:
            if mode == "NETS" and net is not None:
                nets.append((net, cur))
            if mode == "SPECIALNETS" and net is not None:
                specials.append((net, cur))
            net, cur = None, []
            mode = m.group(1)
            continue
        if t.startswith("END COMPONENTS") or t.startswith("END NETS") \
                or t.startswith("END SPECIALNETS") or t.startswith("END PINS"):
            if mode == "NETS" and net is not None:
                nets.append((net, cur))
            if mode == "SPECIALNETS" and net is not None:
                specials.append((net, cur))
            net, cur = None, []
            mode = None
            continue
        if mode == "COMPONENTS":
            if t.startswith("- "):
                parts = t[2:].split()
                if len(parts) >= 2:
                    masters[parts[0]] = parts[1]
        elif mode == "NETS" or mode == "SPECIALNETS":
            if t.startswith("- "):
                if net is not None:
                    (nets if mode == "NETS" else specials).append((net, cur))
                net = t[2:].split()[0]
                cur = []
            else:
                cur += re.findall(r"\(\s*(\S+)\s+(\S+)\s*\)", t)
        elif mode == "PINS":
            if t.startswith("- "):
                pins_declared.append(t[2:].split()[0])
    return masters, pins_declared, nets, specials


def non_filler(masters, conns):
    return [(i, p) for i, p in conns if not masters.get(i, "").startswith(FILLER)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("def_file")
    ap.add_argument("--net")
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--rst", action="store_true")
    a = ap.parse_args()

    masters, ports, nets, specials = read_def(a.def_file)
    print("components %d  ports %d  nets %d  specialnets %d"
          % (len(masters), len(ports), len(nets), len(specials)))

    if a.net:
        want = [n for n, _ in nets if n == a.net] or \
               [n for n, _ in nets if re.search(a.net, n)]
        for name in want[:20]:
            conns = dict(nets)[name]
            print("\n== net %s : %d pins" % (name, len(conns)))
            for i, p in conns:
                print("     %-26s %-6s %s" % (i, p, masters.get(i, "(port)")))
        return

    by_size = collections.Counter()
    for _, conns in nets:
        by_size[len(conns)] += 1
    print("fanout histogram: >1000 %d   >500 %d   >200 %d   >100 %d   >50 %d"
          % (sum(v for k, v in by_size.items() if k > 1000),
             sum(v for k, v in by_size.items() if k > 500),
             sum(v for k, v in by_size.items() if k > 200),
             sum(v for k, v in by_size.items() if k > 100),
             sum(v for k, v in by_size.items() if k > 50)))

    ranked = sorted(((len(c), n, c) for n, c in nets), reverse=True)
    print("\ntop %d nets by pin count:" % a.top)
    for cnt, name, conns in ranked[:a.top]:
        drv = [(i, p, masters.get(i, "(port)")) for i, p in conns
               if p.upper() in DRIVER_PINS]
        loads = collections.Counter(masters.get(i, "(port)") for i, p in conns)
        print("  %-34s pins %6d" % (name, cnt))
        print("        driver : %s" % (drv[:2] if drv else "?"))
        print("        loads  : %s" % loads.most_common(4))

    splits = [i for i in masters if re.match(r"^split\d+$", i)]
    if splits:
        driven = {}
        for name, conns in nets:
            for i, p in conns:
                if i in splits and p.upper() in DRIVER_PINS:
                    driven[i] = (name, len(non_filler(masters, conns)))
        print("\nsplit* instances: %d" % len(splits))
        print("  masters: %s" % collections.Counter(
            masters[i] for i in splits).most_common(6))
        for i, (name, cnt) in sorted(driven.items(),
                                     key=lambda kv: -kv[1][1])[:10]:
            print("  %-9s %-42s drives %-24s loads %5d"
                  % (i, masters.get(i), name, cnt))
        by_net = collections.Counter()
        for i in splits:
            for name, conns in ():
                pass
        print("  output-net load histogram: %s"
              % sorted(collections.Counter(c for _, c in driven.values())
                       .most_common(8)))

    if a.rst:
        print("\nnets matching /rst/i:")
        for cnt, name, conns in ranked:
            if re.search("rst", name, re.I):
                drv = [(i, p, masters.get(i, "(port)")) for i, p in conns
                       if p.upper() in DRIVER_PINS]
                print("  %-34s pins %6d  driver %s" % (name, cnt, drv[:2]))


if __name__ == "__main__":
    sys.exit(main())
