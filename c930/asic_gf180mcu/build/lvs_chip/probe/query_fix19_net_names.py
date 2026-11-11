#!/usr/bin/env python3
"""Read-only: inspect fix19 LVSDB net names around VSS/_083692_. """
import os
import sys
import time
import traceback

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


def toks(name):
    return [t for t in name.split(",") if t]


def main():
    t = time.time()
    print("REPORT", REPORT, flush=True)
    lvs = db.LayoutVsSchematic()
    lvs.read(REPORT)
    print(f"READ {time.time()-t:.1f}s", flush=True)
    top = lvs.netlist().circuit_by_name("grx930_test_chip")
    nets = list(top.each_net())
    print("TOP", nname(top), "NETS", len(nets), flush=True)
    giant = max(nets, key=lambda n: prop(n, "terminal_count", 0) or 0)
    print("GIANT", nname(giant), "terms", prop(giant, "terminal_count", 0), flush=True)

    for n in nets:
        name = nname(n)
        tt = toks(name)
        if "_083692_" in name or "VSS" in tt or "_076858_" in name:
            print("NET", "terms=" + str(prop(n, "terminal_count", 0)),
                  "name=" + name, flush=True)

    print("DONE", f"{time.time()-t:.1f}s", flush=True)
    sys.stdout.flush()
    os._exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.stdout.flush()
        os._exit(1)
