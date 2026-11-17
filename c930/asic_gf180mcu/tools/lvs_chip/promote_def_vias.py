#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Promote a routed DEF's own `VIAS` entries into a supplemental LEF.

`stream_out.py --routing def` builds via cells only from LEF `VIA` definitions.
OpenROAD can instead write generated vias into the DEF's `VIAS` section, where
the geometry lives in `CUTSIZE`, `LAYERS`, `CUTSPACING`, `ENCLOSURE`, and
`ROWCOL`. This script turns those entries into fixed `VIA` blocks that
`stream_out.py` already understands, so neither the streamer's fail-closed
contract nor the PDK LEF has to change.

The DEF is authoritative for geometry. The LEF `VIARULE ... GENERATE` block is
used only to confirm that the named rule exists, that its lower/upper/cut
layers are the ones the DEF names, and that its cut RECT has the DEF's cut
size. The DEF's spacing and enclosure values win over the generator defaults.

    python3 tools/lvs_chip/promote_def_vias.py \
        --def routed.def --lef cells.lef --out routed_vias.lef

Exit status: 0 written, 2 refused (malformed/incomplete input or a collision).
"""

import argparse
import re
import sys
from collections import defaultdict
from fractions import Fraction

UNITS_RE = re.compile(r"(?m)^\s*UNITS\s+DISTANCE\s+MICRONS\s+(\d+)\s*;")
VIAS_RE = re.compile(r"(?m)^\s*VIAS\s+(\d+)\s*;")
END_VIAS_RE = re.compile(r"(?m)^\s*END\s+VIAS\b")
LEF_VIARULE_RE = re.compile(r"^VIARULE\s+(\S+)\s+GENERATE\b")
LEF_LAYER_RE = re.compile(r"^LAYER\s+(\S+)\s*;")
LEF_RECT_RE = re.compile(
    r"^RECT\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*;")
LEF_FIXED_VIA_RE = re.compile(r"(?m)^\s*VIA\s+(\S+)")

CLAUSE_WIDTH = {
    "VIARULE": 1,
    "CUTSIZE": 2,
    "LAYERS": 3,
    "CUTSPACING": 2,
    "ENCLOSURE": 4,
    "ROWCOL": 2,
}
REQUIRED = ("VIARULE", "CUTSIZE", "LAYERS", "CUTSPACING", "ENCLOSURE", "ROWCOL")


def refuse(message):
    """Print a refusal and exit with the documented status 2."""
    print(f"REFUSED  {message}", file=sys.stderr)
    raise SystemExit(2)


def read_text(path, what):
    """Read a text input, refusing an unreadable file with status 2."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError as exc:
        refuse(f"cannot read {what} {path}: {exc}")


def parse_def_units(text, path):
    """Distance units per micron from the DEF header."""
    match = UNITS_RE.search(text)
    if not match:
        refuse(f"{path}: no `UNITS DISTANCE MICRONS` in the DEF header")
    units = int(match.group(1))
    if units <= 0:
        refuse(f"{path}: invalid `UNITS DISTANCE MICRONS {units}`")
    return units


def parse_entry(statement, path):
    """One `- name + CLAUSE ...` entry, with every clause accounted for."""
    tokens = statement.split()
    if not tokens or tokens[0] != "-":
        refuse(f"{path}: VIAS entry does not start with `-`: {statement[:60]!r}")
    if len(tokens) < 2:
        refuse(f"{path}: VIAS entry has no name")
    name = tokens[1]
    fields = {}
    index = 2
    while index < len(tokens):
        if tokens[index] != "+":
            refuse(f"{path}: via {name}: expected `+`, got {tokens[index]!r}")
        if index + 1 >= len(tokens):
            refuse(f"{path}: via {name}: trailing `+`")
        key = tokens[index + 1]
        index += 2
        if key in fields:
            refuse(f"{path}: via {name}: duplicate +{key}")
        width = CLAUSE_WIDTH.get(key)
        if width is None:
            refuse(f"{path}: via {name}: unknown clause +{key}")
        values = tokens[index:index + width]
        if len(values) != width:
            refuse(f"{path}: via {name}: +{key} needs {width} value(s)")
        index += width
        if key == "VIARULE":
            fields[key] = values[0]
        elif key == "LAYERS":
            if len(set(values)) != 3:
                refuse(f"{path}: via {name}: +LAYERS must name three distinct layers")
            fields[key] = tuple(values)
        else:
            if any(not re.fullmatch(r"\d+", value) for value in values):
                refuse(f"{path}: via {name}: +{key} values must be non-negative integers")
            fields[key] = tuple(int(value) for value in values)

    missing = [key for key in REQUIRED if key not in fields]
    if missing:
        refuse(f"{path}: via {name}: missing " + ", ".join(f"+{key}" for key in missing))

    cut_w, cut_h = fields["CUTSIZE"]
    space_x, space_y = fields["CUTSPACING"]
    lower_enclosure_x, lower_enclosure_y, upper_enclosure_x, upper_enclosure_y = \
        fields["ENCLOSURE"]
    rows, cols = fields["ROWCOL"]
    if cut_w <= 0 or cut_h <= 0:
        refuse(f"{path}: via {name}: +CUTSIZE must be positive")
    if space_x < 0 or space_y < 0:
        refuse(f"{path}: via {name}: +CUTSPACING must be non-negative")
    if min(lower_enclosure_x, lower_enclosure_y,
           upper_enclosure_x, upper_enclosure_y) < 0:
        refuse(f"{path}: via {name}: +ENCLOSURE must be non-negative")
    if rows <= 0 or cols <= 0:
        refuse(f"{path}: via {name}: +ROWCOL must be positive")

    return {
        "name": name,
        "viarule": fields["VIARULE"],
        "cut_w": cut_w,
        "cut_h": cut_h,
        "space_x": space_x,
        "space_y": space_y,
        "lower_enclosure_x": lower_enclosure_x,
        "lower_enclosure_y": lower_enclosure_y,
        "upper_enclosure_x": upper_enclosure_x,
        "upper_enclosure_y": upper_enclosure_y,
        "rows": rows,
        "cols": cols,
        "layers": fields["LAYERS"],
    }


def parse_def_vias(path):
    """(DEF units per micron, [via entries]) from the DEF's VIAS section.

    A DEF with no `VIAS` section returns an empty list. A declared count that
    does not match the entries read is refused rather than guessed at.
    """
    text = read_text(path, "DEF")
    units = parse_def_units(text, path)
    header = VIAS_RE.search(text)
    if not header:
        return units, []
    count = int(header.group(1))
    end = END_VIAS_RE.search(text, header.end())
    if not end:
        refuse(f"{path}: VIAS section has no `END VIAS`")
    section = re.sub(r"#[^\n]*", "", text[header.end():end.start()])
    statements = [statement.strip() for statement in section.split(";")
                  if statement.strip()]
    if len(statements) != count:
        refuse(f"{path}: VIAS says {count} entries, but {len(statements)} were read")

    entries = []
    names = set()
    for statement in statements:
        entry = parse_entry(statement, path)
        if entry["name"] in names:
            refuse(f"{path}: duplicate DEF via {entry['name']}")
        names.add(entry["name"])
        entries.append(entry)
    return units, entries


def parse_lef_viarules(path):
    """{name: {layers, rects}} for the LEF's `VIARULE ... GENERATE` blocks."""
    text = read_text(path, "LEF")
    rules = {}
    current = None
    layer = None
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        match = LEF_VIARULE_RE.match(stripped)
        if match:
            if current is not None:
                refuse(f"{path}:{lineno}: VIARULE {current} has no END before {match.group(1)}")
            name = match.group(1)
            if name in rules:
                refuse(f"{path}:{lineno}: duplicate VIARULE {name}")
            rules[name] = {"layers": [], "rects": defaultdict(list)}
            current = name
            layer = None
            continue
        if current is None:
            continue
        if re.match(rf"^END\s+{re.escape(current)}\b", stripped):
            current = None
            layer = None
            continue
        match = LEF_LAYER_RE.match(stripped)
        if match:
            layer = match.group(1)
            rules[current]["layers"].append(layer)
            continue
        match = LEF_RECT_RE.match(stripped)
        if match and layer is not None:
            rules[current]["rects"][layer].append(
                tuple(float(value) for value in match.groups()))
    if current is not None:
        refuse(f"{path}: VIARULE {current} has no END")
    return rules


def parse_lef_via_names(path):
    """Names of fixed LEF `VIA` blocks; a promoted name may not collide."""
    return set(LEF_FIXED_VIA_RE.findall(read_text(path, "LEF")))


def validate_entry(entry, rules, fixed_names, units, lef_path):
    """Check the DEF entry's VIARULE, layer roles, and cut size against the LEF."""
    name = entry["name"]
    if name in fixed_names:
        refuse(f"{lef_path}: DEF via {name} is already a fixed LEF VIA")
    rule = rules.get(entry["viarule"])
    if rule is None:
        refuse(f"{lef_path}: via {name}: unknown VIARULE {entry['viarule']}")
    lef_layers = rule["layers"]
    if len(lef_layers) != 3 or len(set(lef_layers)) != 3:
        refuse(f"{lef_path}: VIARULE {entry['viarule']} must have three distinct LAYERs")
    lower, cut, upper = entry["layers"]
    if cut not in lef_layers or set(lef_layers) != {lower, cut, upper}:
        refuse(f"{lef_path}: via {name}: DEF layers "
               f"{lower}/{cut}/{upper} do not match VIARULE {entry['viarule']} "
               f"layers {lef_layers}")
    rects = rule["rects"].get(cut, [])
    if len(rects) != 1:
        refuse(f"{lef_path}: VIARULE {entry['viarule']} has {len(rects)} cut RECTs on {cut}")
    x0, y0, x1, y1 = rects[0]
    lef_w = int(round(abs(x1 - x0) * units))
    lef_h = int(round(abs(y1 - y0) * units))
    if (lef_w, lef_h) != (entry["cut_w"], entry["cut_h"]):
        refuse(f"{lef_path}: via {name}: VIARULE cut is {lef_w}x{lef_h} DEF units, "
               f"but +CUTSIZE is {entry['cut_w']}x{entry['cut_h']}")


def span(count, size, spacing):
    """Extent of a cut array, in DEF units."""
    return count * size + (count - 1) * spacing


def format_um(half_units, units):
    """Format twice-a-DEF-coordinate in microns without binary-float artefacts."""
    value = Fraction(half_units, 2 * units)
    if value.denominator == 1:
        return str(value.numerator)
    text = f"{float(value):.6f}".rstrip("0").rstrip(".")
    return "0" if text in ("", "-0") else text


def layer_rects(layer, boxes, units):
    """LEF lines for one layer's RECTs; boxes are twice-DEF-unit coordinates."""
    lines = [f"  LAYER {layer} ;"]
    for x0, y0, x1, y1 in boxes:
        lines.append(f"    RECT {format_um(x0, units)} {format_um(y0, units)} "
                     f"{format_um(x1, units)} {format_um(y1, units)} ;")
    return lines


def render(entries, units, def_path):
    """The supplemental LEF: fixed VIA blocks only, no LAYER/WIDTH definitions."""
    lines = [
        f"# Generated by promote_def_vias.py from {def_path}.",
        f"# DEF units: {units}/um. Do not edit; rerun the promoter.",
    ]
    if not entries:
        lines.append("# No DEF VIAS entries; this file intentionally defines no vias.")
    for entry in entries:
        lower, cut, upper = entry["layers"]
        span_x = span(entry["cols"], entry["cut_w"], entry["space_x"])
        span_y = span(entry["rows"], entry["cut_h"], entry["space_y"])
        lower_x = span_x + 2 * entry["lower_enclosure_x"]
        lower_y = span_y + 2 * entry["lower_enclosure_y"]
        upper_x = span_x + 2 * entry["upper_enclosure_x"]
        upper_y = span_y + 2 * entry["upper_enclosure_y"]
        lines.append(f"VIA {entry['name']}")
        lines.extend(layer_rects(lower, [(-lower_x, -lower_y, lower_x, lower_y)], units))
        cuts = []
        pitch_x = entry["cut_w"] + entry["space_x"]
        pitch_y = entry["cut_h"] + entry["space_y"]
        for row in range(entry["rows"]):
            for col in range(entry["cols"]):
                center_x2 = (2 * col - (entry["cols"] - 1)) * pitch_x
                center_y2 = (2 * row - (entry["rows"] - 1)) * pitch_y
                cuts.append((center_x2 - entry["cut_w"], center_y2 - entry["cut_h"],
                             center_x2 + entry["cut_w"], center_y2 + entry["cut_h"]))
        lines.extend(layer_rects(cut, cuts, units))
        lines.extend(layer_rects(upper, [(-upper_x, -upper_y, upper_x, upper_y)], units))
        lines.append(f"END {entry['name']}")
    return "\n".join(lines) + "\n"


def promote(def_path, lef_path, out_path):
    """Validate the DEF's VIAS entries and write the supplemental LEF."""
    units, entries = parse_def_vias(def_path)
    rules = parse_lef_viarules(lef_path)
    fixed_names = parse_lef_via_names(lef_path)
    for entry in entries:
        validate_entry(entry, rules, fixed_names, units, lef_path)
    text = render(entries, units, def_path)
    try:
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(text)
    except OSError as exc:
        refuse(f"cannot write {out_path}: {exc}")
    return len(entries)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Promote DEF VIAS entries into fixed LEF VIA blocks.")
    parser.add_argument("--def", dest="def_file", required=True,
                        help="routed DEF with the VIAS section")
    parser.add_argument("--lef", required=True,
                        help="LEF with the VIARULE ... GENERATE definitions")
    parser.add_argument("--out", required=True,
                        help="supplemental LEF to write")
    args = parser.parse_args(argv)
    count = promote(args.def_file, args.lef, args.out)
    noun = "entry" if count == 1 else "entries"
    print(f"promoted {count} DEF VIAS {noun} to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
