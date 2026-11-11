#!/usr/bin/env python3
"""Read-only: classify the largest fix19 LVSDB nets."""
import os
import sys
import time
import traceback
from collections import Counter

import klayout.db as db

REPORT = os.environ.get(
    "REPORT",
    "/work/c930/asic_gf180mcu/build/lvs_chip/fix19_tile_b12300_y1398/report.lvsdb",
)


def prop(o, n, d=None):
    try:
        v = getattr(o, n)
    except Exception:
        return d
    if callable(v):
        try:
            return v()
        except Exception:
            return d
    return v


def nname(n):
    if n is None:
        return "(nil)"
    for a in ("name", "expanded_name"):
        s = prop(n, a)
        if s:
            return str(s)
    return str(n)


def main():
    t = time.time()
    print("REPORT", REPORT, flush=True)
    lvs = db.LayoutVsSchematic()
    lvs.read(REPORT)
    print(f"READ {time.time()-t:.1f}s", flush=True)
    top = lvs.netlist().circuit_by_name("grx930_test_chip")
    nets = list(top.each_net())
    nets.sort(key=lambda n: prop(n, "terminal_count", 0) or 0, reverse=True)
    print("TOP", nname(top), "NETS", len(nets), flush=True)
    for rank, net in enumerate(nets[:6]):
        terms = prop(net, "terminal_count", 0)
        c = Counter()
        devs = set()
        for term in net.each_terminal():
            dc = prop(term, "device_class")
            dn = prop(dc, "name", "?")
            td = prop(term, "terminal_def")
            tn = prop(td, "name", "?")
            c[(dn, tn)] += 1
            devs.add(prop(prop(term, "device"), "id", -1))
        print(f"NET[{rank}] name={nname(net)} terms={terms} "
              f"devices={len(devs)} pins={prop(net, 'pin_count', '?')}", flush=True)
        for (dn, tn), n in c.most_common(12):
            print(f"  NET[{rank}] {dn} {tn} count={n}", flush=True)
    print(f"DONE {time.time()-t:.1f}s", flush=True)
    sys.stdout.flush()
    os._exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.stdout.flush()
        os._exit(1)
