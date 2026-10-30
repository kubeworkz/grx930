#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Build, and compare, the family evidence -- one committed file for a whole fixture family.

Why this exists
---------------
A single fixture's report is 12 KB, mostly the 295 port names of one device. Fourteen of those is
160 KB of evidence nobody reads, and the parts that decide are small: for each fixture, did the
devices match, did the ports pass, and which inputs (hashes) was that about. This projects each
fixture's own verdict.json down to those fields, in a fixed order, so the committed file is a
readable list and two runs of the same inputs produce the same bytes.

    lvs_family.py build --manifest M.tsv --runs DIR --out FILE [--pin REPO@SHA]
    lvs_family.py compare OLD NEW      # SAME, or DIFF with the keys that moved

`build` reads DIR/<category>__<fixture>/verdict.json -- the layout the refresh job writes -- and
refuses to guess: a missing report, or one without the fields that decide, is an error rather than
an entry with empty fields, because an aggregate that silently omits a fixture is exactly the
evidence failure this file exists to prevent.
"""

import argparse
import hashlib
import json
import os
import sys

# Fields that move between runs of the same inputs: the report's own paths. Everything else is
# compared, which is why `deck.path` is dropped but `deck.sha256` is not.
VOLATILE = {"deck": ("path",)}

# The projection of one fixture's report. `schematic` is kept as a count and a digest rather than
# 295 names: a port list that changed is a real finding, and a digest says so in 64 characters.
PORT_FIELDS = (
    "checked",
    "verdict",
    "checked_by",
    "deck_variable_defined",
    "layout_pin_count",
    "missing_in_layout",
    "layout_only",
)


def read_manifest(path):
    """[(category/fixture, "k=v,k=v"), ...] -- comments and blank lines skipped."""
    entries = []
    for raw in open(path, encoding="utf-8").read().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        name = parts[0].strip()
        if "/" not in name:
            raise SystemExit(f"manifest {path}: not <category>/<fixture>: {line!r}")
        entries.append((name, parts[1].strip() if len(parts) > 1 else ""))
    return entries


def sha_list(names):
    h = hashlib.sha256()
    for name in sorted(names):
        h.update(name.encode())
        h.update(b"\n")
    return h.hexdigest()[:16]


def project(report, fixture, switches):
    devices = report.get("devices") or {}
    ports = report.get("ports") or {}
    inputs = report.get("inputs") or {}
    entry = {
        "fixture": fixture,
        "switches": switches,
        "verdict": report.get("verdict"),
        "devices": {
            "verdict": devices.get("verdict"),
            "instances_extracted": devices.get("instances_extracted"),
            "instances_schematic": devices.get("instances_schematic"),
        },
        "ports": {k: ports.get(k) for k in PORT_FIELDS},
        "inputs": {
            k: (inputs.get(k) or {}).get("sha256") for k in ("layout", "netlist")
        },
    }
    schematic = ports.get("schematic")
    if isinstance(schematic, list):
        entry["ports"]["schematic_count"] = len(schematic)
        entry["ports"]["schematic_sha256_16"] = sha_list(schematic)
    # Whatever the deck was run with, so a green cannot come from switches nobody recorded.
    entry["deck_switches"] = report.get("deck_switches") or {}
    return entry


def cmd_build(args):
    entries = read_manifest(args.manifest)
    fixtures = []
    missing = []
    for fixture, switches in entries:
        report_path = os.path.join(args.runs, fixture.replace("/", "__"), "verdict.json")
        if not os.path.isfile(report_path):
            missing.append(report_path)
            continue
        report = json.load(open(report_path))
        for key in ("verdict", "devices", "ports", "inputs"):
            if key not in report:
                missing.append(f"{report_path} (no '{key}')")
        fixtures.append(project(report, fixture, switches))
    if missing:
        print("lvs_family: no usable report for:\n  " + "\n  ".join(missing), file=sys.stderr)
        return 2

    fixtures.sort(key=lambda e: e["fixture"])
    # The deck is one file for the whole family, so its hash belongs to the aggregate rather than
    # to each entry; taken from the first report that names one. Its path is dropped -- two runs of
    # the same inputs from different directories are the same evidence.
    deck = {}
    for entry in fixtures:
        report_path = os.path.join(args.runs, entry["fixture"].replace("/", "__"), "verdict.json")
        named = (json.load(open(report_path)).get("inputs") or {}).get("deck")
        if named:
            deck = {k: v for k, v in named.items() if k not in VOLATILE.get("deck", ())}
            break

    aggregate = {
        "kind": "family",
        "pin": args.pin,
        "deck": deck,
        "fixtures": fixtures,
        "summary": {
            "total": len(fixtures),
            "match": sum(1 for f in fixtures if f["verdict"] == "match"),
            "mismatch": sum(1 for f in fixtures if f["verdict"] != "match"),
        },
    }
    with open(args.out, "w") as fh:
        json.dump(aggregate, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print(
        "family   {} fixtures, {} match, {} not".format(
            aggregate["summary"]["total"],
            aggregate["summary"]["match"],
            aggregate["summary"]["mismatch"],
        )
    )
    print(f"written  {args.out}")
    return 0


def compare(old_path, new_path):
    old = json.load(open(old_path))
    new = json.load(open(new_path))
    diffs = []

    def walk(a, b, path):
        if isinstance(a, dict) and isinstance(b, dict):
            for key in sorted(set(a) | set(b)):
                walk(a.get(key), b.get(key), f"{path}.{key}" if path else key)
        elif isinstance(a, list) and isinstance(b, list):
            if len(a) != len(b):
                diffs.append(f"{path} (length {len(a)} -> {len(b)})")
                return
            for i, (x, y) in enumerate(zip(a, b)):
                walk(x, y, f"{path}[{i}]")
        elif a != b:
            diffs.append(path)

    # deck.path is a path, not a fact about the verdict; everything else in `deck` is a fact. The
    # aggregation drops it too, so this only matters for a hand-edited or older file.
    for side in (old, new):
        if isinstance(side.get("deck"), dict):
            side["deck"] = {k: v for k, v in side["deck"].items() if k not in VOLATILE["deck"]}
    walk(old, new, "")
    # Only the first few, and short names: a summary with 300 lines is not a summary.
    short = [d for d in diffs if d]
    if not short:
        print("SAME")
        return 0
    print("DIFF " + ", ".join(short[:6]) + (f" (+{len(short) - 6} more)" if len(short) > 6 else ""))
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="project per-fixture reports into the family aggregate")
    b.add_argument("--manifest", required=True)
    b.add_argument("--runs", required=True, help="directory holding <category>__<fixture>/verdict.json")
    b.add_argument("--out", required=True)
    b.add_argument("--pin", default="", help="REPO@SHA the reports came from, recorded as-is")
    b.set_defaults(func=cmd_build)

    c = sub.add_parser("compare", help="compare two aggregates")
    c.add_argument("old")
    c.add_argument("new")
    c.set_defaults(func=lambda a: compare(a.old, a.new))

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
