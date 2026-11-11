#!/usr/bin/env python3
"""Read-only fix20 xref query using each_net_pair (no net_pair_for)."""
import os
import sys
import time
import traceback
from collections import Counter

import klayout.db as db

REPORT = os.environ.get(
    "REPORT",
    "/work/c930/asic_gf180mcu/build/lvs_chip/fix20_tile_b12300_y1398/report.lvsdb",
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


def terms(n):
    v = prop(n, "terminal_count", 0)
    return v if isinstance(v, int) else 0


def sides(p):
    return prop(p, "first"), prop(p, "second")


def netdesc(n):
    if n is None:
        return "(nil)"
    return f'"{nname(n)}" terms={terms(n)}'


def interesting(a, b):
    n = nname(a) + " " + nname(b)
    return ("VDD" in n or "VSS" in n or "_076858_" in n
            or terms(a) > 100000 or terms(b) > 100000)


def main():
    t = time.time()
    print("REPORT", REPORT, flush=True)
    lvs = db.LayoutVsSchematic()
    lvs.read(REPORT)
    print(f"READ {time.time()-t:.1f}s", flush=True)
    top = lvs.netlist().circuit_by_name("grx930_test_chip")
    ref = lvs.reference
    if callable(ref):
        ref = ref()
    rtop = ref.circuit_by_name("GRX930_TEST_CHIP") or ref.top_circuit()
    xref = lvs.xref()
    print("XREF_TYPE", type(xref).__name__, flush=True)
    print("XREF_METHODS", [m for m in dir(xref) if not m.startswith("_")], flush=True)

    cp = None
    try:
        cps = list(xref.each_circuit_pair())
        print("CIRCUIT_PAIRS", len(cps), flush=True)
        for p in cps:
            a, b = sides(p)
            print("  CP", netdesc(a), "<->", netdesc(b), flush=True)
            if a is not None and b is not None and cp is None:
                cp = p
    except Exception as e:
        print("CIRCUIT_PAIR_ERROR", type(e).__name__, e, flush=True)

    statuses = Counter()
    n = 0
    shown = 0
    try:
        pairs = xref.each_net_pair(cp) if cp is not None else xref.each_net_pair()
        for p in pairs:
            n += 1
            a, b = sides(p)
            st = str(prop(p, "status", "?"))
            statuses[st] += 1
            if interesting(a, b) and shown < 120:
                print("PAIR", st, netdesc(a), "<->", netdesc(b), flush=True)
                shown += 1
    except Exception as e:
        print("NET_PAIR_ERROR", type(e).__name__, e, flush=True)
        traceback.print_exc()

    print("PAIR_COUNT", n, "STATUSES", dict(statuses), flush=True)
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
