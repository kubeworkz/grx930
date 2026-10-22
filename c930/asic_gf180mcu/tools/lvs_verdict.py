#!/usr/bin/env python3
"""Judge a KLayout LVS verdict file. One line, one exit status, no opinion about layouts.

Why this exists: the tapeout gate table (build/chip_gates.sh) branches on an exit status and a
literal evidence line, so the decision "may this LVS report be called green" has to live in a
program that can be tested without docker, without a PDK and without a layout. `klayout_lvs.py`
produces the report; this reads it.

The three answers are deliberately different exit statuses, because "we have no verdict" and "the
verdict is bad" are different failures and a gate must not conflate them:

    0  PASS        verdict AND devices AND ports all good, and the report is about the inputs on
                   disk (when those inputs are given and present)
    1  MISMATCH    the report says the netlists (or the ports) do not agree, or the report is
                   about different inputs than the ones on disk
    2  CANNOT-RUN  no report, unreadable report, a report without the fields that decide, or a
                   port check that was skipped -- nothing here is evidence either way

Usage:
    lvs_verdict.py --report verdict.json [--layout L] [--netlist N] [--deck D]

Two shapes are understood, and the second is what the repo's evidence now is:

  * a single report from `klayout_lvs.py` (one layout against one schematic) -- this is also the
    shape a chip run produces, and the one `--layout/--netlist/--deck` apply to;
  * a **family** aggregate from `lvs_family.py`: one file for a list of fixtures, each entry with
    its own devices/ports/input hashes. Every fixture must be green, and none may have skipped the
    port check; `--deck` is compared against the family's recorded deck hash, and `--layout` /
    `--netlist` do not apply (each fixture has its own, and `lvs_fetch_pdk_subset.sh` ties those to
    the pin).

`--layout/--netlist/--deck` are optional and are used for one purpose: if the file exists, its
sha256 must be the one recorded in the report. That is what stops a green report from an older
run (or a different fixture) from being presented as the current one. A path that does not exist
is noted and skipped -- a CI checkout has no PDK install, and the verdict is still the artifact
under review there.
"""

import argparse
import hashlib
import json
import os
import sys


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cannot_run(reason):
    print(f"LVS: CANNOT-RUN {reason}")
    return 2


def mismatch(reason):
    print(f"LVS: MISMATCH {reason}")
    return 1


def judge_family(report, args):
    """Every fixture in the family must be green, and one bad entry is enough to fail it."""
    entries = report.get("fixtures") or []
    if not isinstance(entries, list) or not entries:
        return cannot_run(f"{args.report} has a 'fixtures' key with no fixtures in it")

    # The deck hash is the one input the whole family shares; the rest are per fixture.
    if args.deck:
        recorded = (report.get("deck") or {}).get("sha256")
        if not os.path.isfile(args.deck):
            note = "deck absent here, so the family was not tied to the one on disk"
        elif not recorded:
            return cannot_run(f"the family records no deck hash, so it cannot be tied to {args.deck}")
        elif sha256(args.deck) != recorded:
            return mismatch(
                f"the family is not about the deck on disk: {sha256(args.deck)[:16]} != {recorded[:16]}"
            )
        else:
            note = ""
    else:
        note = ""

    bad, skipped = [], []
    for entry in entries:
        name = entry.get("fixture") or "?"
        devices = (entry.get("devices") or {}).get("verdict")
        ports = entry.get("ports") or {}
        if not ports.get("checked"):
            skipped.append(name)
        elif devices != "match" or ports.get("verdict") != "pass" or entry.get("verdict") != "match":
            missing = ports.get("missing_in_layout") or []
            why = f"devices {devices}" if devices != "match" else "ports"
            if missing:
                why += f" (missing {', '.join(missing[:3])})"
            bad.append(f"{name}: {why}")

    if skipped:
        return cannot_run(f"these fixtures skip the port comparison: {', '.join(skipped[:4])}")
    if bad:
        return mismatch(f"{len(bad)} of {len(entries)} fixtures: " + "; ".join(bad[:4]))

    summary = report.get("summary") or {}
    pin = report.get("pin") or ""
    print(
        "LVS: PASS family={} match={} pin={} report={}{}".format(
            summary.get("total", len(entries)),
            summary.get("match", len(entries)),
            pin or "unrecorded",
            args.report,
            ("; " + note) if note else "",
        )
    )
    return 0


def main():
    ap = argparse.ArgumentParser(description="Judge a KLayout LVS verdict file.")
    ap.add_argument("--report", required=True, help="verdict.json written by klayout_lvs.py")
    ap.add_argument("--layout", help="layout the report is supposed to describe")
    ap.add_argument("--netlist", help="schematic the report is supposed to describe")
    ap.add_argument("--deck", help="deck the report is supposed to have used")
    args = ap.parse_args()

    if not os.path.isfile(args.report):
        return cannot_run(f"no report at {args.report}")
    try:
        with open(args.report) as fh:
            report = json.load(fh)
    except (ValueError, OSError) as exc:
        return cannot_run(f"{args.report} is not readable JSON ({exc})")

    if "fixtures" in report:
        return judge_family(report, args)

    for key in ("verdict", "devices", "ports", "inputs"):
        if key not in report:
            return cannot_run(f"{args.report} has no '{key}' field; not a verdict this gate knows")

    # Staleness: a report is only about the files it recorded.
    stale, unverified = [], []
    for label, path in (("layout", args.layout), ("netlist", args.netlist), ("deck", args.deck)):
        if not path:
            continue
        recorded = (report.get("inputs", {}).get(label) or {}).get("sha256")
        if not os.path.isfile(path):
            unverified.append(f"{label} absent")
            continue
        if not recorded:
            return cannot_run(f"report records no {label} hash, so it cannot be tied to {path}")
        actual = sha256(path)
        if actual != recorded:
            stale.append(f"{label} sha256 {actual[:16]} != report {recorded[:16]}")
    if stale:
        return mismatch("report is not about the inputs on disk: " + "; ".join(stale))

    devices = (report.get("devices") or {}).get("verdict")
    ports = report.get("ports") or {}
    if not ports.get("checked"):
        # klayout_lvs.py sets this false only when asked to skip the comparison; a skipped check
        # is not a passing one, and the deck's own check is dead (see klayout_lvs.py).
        return cannot_run("the report skips the port comparison; there is no port evidence")
    if devices != "match":
        return mismatch(f"devices: {devices}")
    if ports.get("verdict") != "pass":
        missing = ports.get("missing_in_layout") or []
        detail = f"missing ports: {', '.join(missing[:8])}" if missing else "ports did not pass"
        return mismatch(detail)
    if report.get("verdict") != "match":
        return mismatch(f"report verdict is {report.get('verdict')!r}")

    note = ("; " + ", ".join(unverified)) if unverified else ""
    print(
        "LVS: PASS devices=match ports=pass extracted={} schematic={} report={}{}".format(
            (report.get("devices") or {}).get("instances_extracted"),
            (report.get("devices") or {}).get("instances_schematic"),
            args.report,
            note,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
