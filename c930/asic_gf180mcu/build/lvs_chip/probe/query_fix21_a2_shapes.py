#!/usr/bin/env python3
"""Read-only: print the exact A2 pair and the LVS shapes of A2/_076858_."""
import os
import sys
import time
import traceback

import klayout.db as db

REPORT = os.environ.get(
    "REPORT",
    "/work/c930/asic_gf180mcu/build/lvs_chip/fix20_tile_b12300_y1398/report.lvsdb",
)
TOP = "grx930_test_chip"


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


def bbox(r):
    try:
        b = r.bbox()
        return f"({b.left},{b.bottom};{b.right},{b.top})"
    except Exception:
        return "NONE"


def layer_names(lvs):
    for attr in ("layer_names", "layer_names_"):
        v = prop(lvs, attr)
        if v:
            return list(v)
    return []


def shape_rows(lvs, net, names):
    print("SHAPES_BEGIN", nname(net), "terms", terms(net), flush=True)
    for name in names:
        try:
            layer = lvs.layer_by_name(name)
        except Exception as e:
            print("  LAYER_ERROR", repr(name), type(e).__name__, e, flush=True)
            continue
        if layer is None:
            continue
        try:
            r = lvs.shapes_of_net(net, layer)
        except Exception as e:
            print("  SHAPES_ERROR", repr(name), type(e).__name__, e, flush=True)
            continue
        if r is None or r.size() == 0:
            continue
        print(f"  LAYER {name!r} count={r.size()} bbox={bbox(r)}", flush=True)
        for p in list(r.each())[:30]:
            print(f"    POLY {p.bbox()}", flush=True)
    print("SHAPES_END", nname(net), flush=True)


def main():
    t = time.time()
    print("REPORT", REPORT, flush=True)
    lvs = db.LayoutVsSchematic()
    lvs.read(REPORT)
    print(f"READ {time.time()-t:.1f}s", flush=True)
    print("LVS_METHODS", [m for m in dir(lvs) if
          ("shape" in m or "layer" in m or "layout" in m)], flush=True)

    top = lvs.netlist().circuit_by_name(TOP) or lvs.netlist().top_circuit()
    xref = lvs.xref()
    cp = next(iter(xref.each_circuit_pair()), None)
    target = None
    other = None
    for p in xref.each_net_pair(cp):
        a, b = prop(p, "first"), prop(p, "second")
        if nname(b) == "_076858_" or nname(a) == "_076858_":
            print("PAIR", prop(p, "status"), nname(a), terms(a),
                  "<->", nname(b), terms(b), flush=True)
            if nname(a) == "A2":
                target, other = a, b
                break
    if target is None:
        print("NO_A2_PAIR", flush=True)
        return 1

    print("TARGET", nname(target), "terms", terms(target), flush=True)
    for attr in ("each_terminal_ref", "each_pin_ref", "each_subcircuit_pin_ref"):
        fn = getattr(target, attr, None)
        print("TARGET_ATTR", attr, "exists", fn is not None, flush=True)
        if fn is None:
            continue
        try:
            rows = list(fn())
            print("TARGET_REFS", attr, len(rows), flush=True)
            for r in rows[:20]:
                print("  REF", r, "pin", prop(r, "pin"),
                      "subcircuit", prop(r, "subcircuit"), flush=True)
        except Exception as e:
            print("TARGET_REFS_ERROR", attr, type(e).__name__, e, flush=True)

    names = layer_names(lvs)
    print("LAYER_NAMES", len(names), names[:20], flush=True)
    if names:
        shape_rows(lvs, target, names)
        # The other layout net with the _076858_ label.
        for n in top.each_net():
            if nname(n) == "I0,I1,_076858_":
                shape_rows(lvs, n, names)
                break

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
