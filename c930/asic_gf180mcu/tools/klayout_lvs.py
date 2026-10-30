#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""KLayout LVS on a GF180MCU layout/schematic pair, with a verdict that can be trusted.

Why this exists
---------------
The PDK's own ``gf180mcu.lvs`` deck cannot run with its advertised default. The comparison
section ends with::

    result &= flag_missing_ports if CHECK_PORTS

``CHECK_PORTS`` defaults to *true*, and ``flag_missing_ports`` is never assigned anywhere: not in
the deck shipped in this tree (``libs.tech/klayout/tech/lvs/gf180mcu.lvs``, sha256 recorded in
every report), not in any ``rule_decks/*.lvs`` beside it, and not at upstream ``main`` of
``fossi-foundation/globalfoundries-pdk-libs-gf180mcu_fd_pv`` (checked 2026-10-17, commits
9ba05b0 "implement flag_missing_ports" and 355b9ee "do not use shortcut logic ..." both reference
the name without defining it). Every invocation with the default therefore dies with
``undefined local variable or method 'flag_missing_ports'`` -- including the PDK's own
``run_lvs.py``, whose option list has no ``--check_ports`` to turn the check off. This is not a
deck/runner version skew: no copy of either defines the variable, so the check has never run.

So this tool runs the deck with ``check_ports=false`` and performs that comparison itself: every
top-level port of the schematic must exist among the layout's top-level pins. The deck emits
those pins from net labels when ``top_lvl_pins`` is on, so a schematic port with no matching
label is a missing port -- which is what the deck's dead check was supposed to catch. Extra
layout pins are not an error: ``top_lvl_pins`` promotes every labelled net, not only the ports.

The second default that matters: ``combine=false`` leaves each MOSFET finger as its own device,
so a multi-finger fixture can never match. The PDK's own per-device config
(``lvs/testing/unit/mos_devices/config/default.yaml``) sets ``combine: true`` for
``nfet_05v0``; this tool does the same, and a negative control in the selftest shows the
comparison still discriminates with it on.

Runs inside the flow image (python3 + klayout on PATH); ``tools/klayout_lvs.sh`` is the host
wrapper that mounts the tree and passes paths through.

Exit codes: 0 = match, 1 = mismatch, 2 = could not run (missing input, deck error before the
comparison). A mismatch is a finding, not a crash.
"""

import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

DECK_SWITCHES = {
    # Comparison semantics. `combine` and `check_ports` are the two defaults that decide whether a
    # correct pair can match at all; see the module docstring.
    "combine": "true",
    "check_ports": "false",
    "top_lvl_pins": "true",
    "run_mode": "deep",
    "verbose": "false",
}


CONTAINER_ROOT = "/work"


def rel(path):
    """Path as the repo sees it: the tree is mounted at /work inside the container."""
    path = os.path.abspath(path)
    prefix = CONTAINER_ROOT + os.sep
    return path[len(prefix):] if path.startswith(prefix) else path


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def project_spice(path):
    """Join ``+`` continuations so one statement is one line."""
    out = []
    for raw in open(path, errors="replace").read().splitlines():
        if raw.startswith("+") and out:
            out[-1] = out[-1] + " " + raw[1:].strip()
        else:
            out.append(raw)
    return out


def subckts(path):
    """{lowercase name: [pins]} for every .SUBCKT in a SPICE/CDL file."""
    found = {}
    for line in project_spice(path):
        stripped = line.strip()
        if stripped.lower().startswith(".subckt"):
            parts = stripped.split()
            if len(parts) >= 2:
                found[parts[1].lower()] = parts[2:]
    return found


def count_devices(path):
    """Instance count of the first-level devices (M/R/C/D/Q/E/F/H/L lines)."""
    return sum(
        1
        for line in project_spice(path)
        if line[:1] in "MmRrCcDdQqEeFfHhLl" and not line.startswith("*")
    )


def layout_pins(path):
    """Top-level pins of the extracted netlist: the .SUBCKT pins plus any `* pin` comments.

    Both are read because the deck writes the comment form when comments are enabled and the
    .SUBCKT form always; either alone is authoritative, together they are redundant on purpose.
    """
    pins = set()
    text = open(path, errors="replace").read()
    for name in re.findall(r"(?m)^\*\s*pin\s+(\S+)", text):
        pins.add(name)
    for _subckt, plist in subckts(path).items():
        pins.update(plist)
    return pins


def main():
    ap = argparse.ArgumentParser(description="KLayout LVS with a port check that actually runs.")
    ap.add_argument("--deck", required=True, help="gf180mcu.lvs (run in place: it expands `# %%include`)")
    ap.add_argument("--layout", required=True, help="layout (.gds/.oas, optionally .gz)")
    ap.add_argument("--netlist", required=True, help="schematic (.cdl/.spice)")
    ap.add_argument("--out", required=True, help="output directory for log, netlist, lvsdb, verdict")
    ap.add_argument("--topcell", default=None, help="top cell name; defaults to the schematic's first .SUBCKT")
    ap.add_argument("--no-port-check", action="store_true", help="report the device verdict alone")
    ap.add_argument(
        "--implicit-connect",
        action="store_true",
        help="deck switch the PDK's per-device config asks for on some fixtures (e.g. pfet_05v0)",
    )
    ap.add_argument(
        "--switch",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="extra deck switch, repeatable; the PDK's per-fixture configs name these "
        "(poly_res=2k, metal_level=5LM, consider_dn_dw_features=true, ...)",
    )
    args = ap.parse_args()

    for label, path in (("deck", args.deck), ("layout", args.layout), ("netlist", args.netlist)):
        if not os.path.isfile(path):
            print(f"SETUP  {label} not found: {path}", file=sys.stderr)
            return 2

    os.makedirs(args.out, exist_ok=True)
    deck_text = open(args.deck, errors="replace").read()
    # The deck is run in place because KLayout expands its `# %include rule_decks/...` lines
    # relative to the deck's own directory; a copy without rule_decks beside it extracts nothing
    # and would compare two empty netlists.
    deck_rule_decks = os.path.join(os.path.dirname(args.deck), "rule_decks")
    if "# %include" in deck_text and not os.path.isdir(deck_rule_decks):
        print(f"SETUP  deck expands `# %include` but {deck_rule_decks} is missing", file=sys.stderr)
        return 2
    port_check_dead = "flag_missing_ports" in deck_text and not re.search(
        r"flag_missing_ports\s*=", deck_text
    )

    # Layout: decompress into the output dir so the run is self-describing.
    layout = args.layout
    if layout.endswith(".gz"):
        layout = os.path.join(args.out, "input.gds")
        with gzip.open(args.layout, "rb") as src, open(layout, "wb") as dst:
            shutil.copyfileobj(src, dst)

    # The deck's logger shells out to `pmap`; the flow images do not ship it, and `nil.strip` then
    # kills the run before the layout is read.
    bindir = os.path.join(args.out, "bin")
    os.makedirs(bindir, exist_ok=True)
    pmap = os.path.join(bindir, "pmap")
    with open(pmap, "w") as fh:
        fh.write("#!/bin/sh\necho '1234567 000'\n")
    os.chmod(pmap, 0o755)
    env = dict(os.environ)
    env["PATH"] = bindir + os.pathsep + env.get("PATH", "")

    schematic = subckts(args.netlist)
    topcell = args.topcell or (next(iter(schematic)) if schematic else None)
    if not topcell:
        print(f"SETUP  no .SUBCKT in {args.netlist}", file=sys.stderr)
        return 2

    extracted = os.path.join(args.out, "extracted.cir")
    lvsdb = os.path.join(args.out, "report.lvsdb")
    log_path = os.path.join(args.out, "klayout.log")
    cmd = ["klayout", "-b", "-r", args.deck]
    switches = dict(DECK_SWITCHES)
    if args.implicit_connect:
        switches["implicit_connect"] = "true"
    for item in args.switch:
        # A switch without a value is a typo that would otherwise be passed through to the deck as
        # a bare `-rd`, which KLayout accepts and the deck then evaluates as nil -- a silent change
        # of meaning, so it stops here instead.
        if "=" not in item:
            print(f"SETUP  --switch wants KEY=VALUE, got: {item}", file=sys.stderr)
            return 2
        key, value = item.split("=", 1)
        if not key.strip():
            print(f"SETUP  --switch with an empty name: {item}", file=sys.stderr)
            return 2
        switches[key.strip()] = value
    switches.update(
        input=layout,
        schematic=args.netlist,
        topcell=topcell,
        report=lvsdb,
        target_netlist=extracted,
    )
    for key, value in switches.items():
        cmd += ["-rd", f"{key}={value}"]

    with open(log_path, "w") as log:
        log.write("$ " + " ".join(cmd) + "\n")
        log.flush()
        proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, env=env)
    log_text = open(log_path, errors="replace").read()

    device_match = "Congratulations! Netlists match" in log_text
    device_mismatch = "Netlists don't match" in log_text
    errored = re.search(r"(Traceback|undefined local variable|undefined method|ERROR)", log_text)

    if not (device_match or device_mismatch):
        tail = [l for l in log_text.splitlines() if "Memory Usage" not in l][-8:]
        print("SETUP  the deck produced no verdict:", file=sys.stderr)
        print("\n".join("       " + l for l in tail), file=sys.stderr)
        return 2

    # Port comparison: the deck's dead check, done here.
    sch_pins, lay_pins = set(), set()
    missing, extra = [], []
    if os.path.isfile(extracted):
        lay_pins = layout_pins(extracted)
    sch_pins = set(schematic.get(topcell.lower(), []))
    if not args.no_port_check and lay_pins:
        missing = sorted(p for p in sch_pins if p not in lay_pins)
        extra = sorted(p for p in lay_pins if p not in sch_pins)

    ports_ok = not missing
    verdict_match = device_match and (ports_ok or args.no_port_check)

    verdict = {
        "verdict": "match" if verdict_match else "mismatch",
        "devices": {
            "verdict": "match" if device_match else "mismatch",
            "instances_extracted": count_devices(extracted) if os.path.isfile(extracted) else None,
            "instances_schematic": count_devices(args.netlist),
        },
        "ports": {
            "checked": not args.no_port_check,
            "verdict": "pass" if ports_ok else "fail",
            "schematic": sorted(sch_pins),
            "layout_pin_count": len(lay_pins),
            "missing_in_layout": missing,
            "layout_only": extra,
            "checked_by": "klayout_lvs.py" if port_check_dead else "gf180mcu.lvs",
            "deck_variable_defined": not port_check_dead,
        },
        "topcell": topcell,
        # What the comparison actually ran with, minus the paths: this is what makes a verdict
        # reproducible from the report alone, and it is what the family evidence compares.
        "deck_switches": {
            k: v for k, v in switches.items() if k not in ("input", "schematic", "report", "target_netlist", "topcell")
        },
        "inputs": {
            "deck": {"path": rel(args.deck), "sha256": sha256(args.deck)},
            "layout": {"path": rel(args.layout), "sha256": sha256(args.layout)},
            "netlist": {"path": rel(args.netlist), "sha256": sha256(args.netlist)},
        },
        "artifacts": {
            "log": rel(log_path),
            "extracted_netlist": rel(extracted),
            "lvsdb": rel(lvsdb),
        },
        "paths_relative_to": "repository root",
        "deck_error_text": (errored.group(0) if errored else None),
    }
    with open(os.path.join(args.out, "verdict.json"), "w") as fh:
        json.dump(verdict, fh, indent=2, sort_keys=True)
        fh.write("\n")

    v = verdict
    print(f"topcell  {topcell}")
    print(f"deck     {os.path.basename(args.deck)}  sha256 {v['inputs']['deck']['sha256'][:16]}")
    if port_check_dead:
        print("note     deck references `flag_missing_ports` without defining it; port check is done here")
    print(
        "devices  {:8s} extracted {} instances, schematic {}".format(
            v["devices"]["verdict"].upper(),
            v["devices"]["instances_extracted"],
            v["devices"]["instances_schematic"],
        )
    )
    if args.no_port_check:
        print("ports    SKIPPED  (--no-port-check)")
    else:
        print(
            "ports    {:8s} schematic {} ports, layout {} pins, missing {}".format(
                v["ports"]["verdict"].upper(),
                len(v["ports"]["schematic"]),
                v["ports"]["layout_pin_count"],
                v["ports"]["missing_in_layout"] or "none",
            )
        )
    print(f"verdict  {v['verdict'].upper()}   ({rel(args.out)}/)")
    return 0 if verdict_match else 1


if __name__ == "__main__":
    sys.exit(main())
