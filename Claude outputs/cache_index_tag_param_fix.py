#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Apply the cache index/tag parameterization (the openlane2_rtl/src fix) to
every cache source copy under rv64imac/, so no cache instantiation at any
INDEX_WIDTH can serve a wrong line.

Per cache file (controller / memory / top, dcache and icache):
  * the tag and index slices derive from the module parameters:
        TAG   = ADDR_WIDTH-1 : 5+INDEX_WIDTH
        index = 5 +: INDEX_WIDTH
    instead of the literals 63:12 / 11:5 which are only correct at
    INDEX_WIDTH = 7 and alias 2**(7-INDEX_WIDTH) tag entries per data line.
  * dcache and icache get distinct macro names (DCACHE_/ICACHE_ prefixed) so
    the two files can be compiled together without one clobbering the other.
  * controllers size the tag array from the split (TAG_W) rather than from the
    TAG_WIDTH parameter, and $error in simulation if an explicitly overridden
    TAG_WIDTH disagrees.
  * memories index the data array with 5 +: INDEX_WIDTH, never 11 -: / 11:5.
  * tops derive the TAG_WIDTH default from the split and pass INDEX_WIDTH down
    to their controller and memory.

Binary-safe: files are read/written as latin-1 bytes so existing CRLF files
stay CRLF.  The script refuses a file that does not carry the literal macros
(it is not idempotent on purpose).

Usage:  python apply_cache_param_fix.py [--check]
        --check  only report what would change, write nothing
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# (path relative to repo root, kind, role, tree label)
FILES = []
for tree, prefix in [
    ("rv64imac/RTL", ""),
    ("rv64imac/RTL/caches", ""),
    ("rv64imac/RTL/caches/atomic_dcaches", ""),
    ("rv64imac/FPGA/src", ""),
]:
    for kind in ("dcache", "icache"):
        if kind == "icache" and "atomic_dcaches" in tree:
            continue  # that archive has no icache copy
        for role in ("controller", "memory", "top"):
            FILES.append(
                (f"{tree}/riscv_core_{kind}_{role}.sv", kind, role, tree)
            )

# Core tops that instantiate the caches: keep the TAG_WIDTH override derived
# from the same width parameter (or drop the stale literal).
CORE_TOPS = [
    "rv64imac/RTL/riscv_core_top.sv",
    "rv64imac/FPGA/src/riscv_core_top.sv",
    "rv64imac/RTL/Branch_Predicition/TOP WITH BRANCH PREDICTION/riscv_core_top.sv",
]

HEADER = {
    "controller": (
        "// INDEX/TAG SPLIT -- both selects derive from INDEX_WIDTH, never from literals.\n"
        "// A literal addr[11:5] set select over an INDEX_WIDTH-wide data array aliases\n"
        "// 2**(7-INDEX_WIDTH) tag entries onto one data line, so a fill can leave a\n"
        "// foreign tag VALID over that line and a later HIT serves the wrong line.\n"
        "//   index = addr[5 +: INDEX_WIDTH]   tag = addr[ADDR_WIDTH-1 : 5+INDEX_WIDTH]\n"
    ),
    "memory": (
        "// Index select must match the tag array's set select in the controller: the\n"
        "// set is addr[5 +: INDEX_WIDTH], never the literal addr[11:5] this file used\n"
        "// to carry (2**(7-INDEX_WIDTH) tag entries aliased onto one data line at\n"
        "// INDEX_WIDTH < 7).  See the controller for the failure mode.\n"
    ),
    "top": (
        "// INDEX/TAG SPLIT -- the selects derive from INDEX_WIDTH and the TAG_WIDTH\n"
        "// default follows the split, so an instantiation at any width gets tag bits\n"
        "// that still reconstruct the line (see the controller note).\n"
    ),
}


def transform(text: str, kind: str, role: str) -> tuple[str, int]:
    nl = "\r\n" if "\r\n" in text else "\n"
    idx = "DCACHE_INDEX" if kind == "dcache" else "ICACHE_INDEX"
    blk = ("DCACHE" if kind == "dcache" else "ICACHE") + "_BLOCK_OFFSET"
    byt = ("DCACHE" if kind == "dcache" else "ICACHE") + "_BYTE_OFFSET"
    changes = 0

    def sub(pattern, repl, s):
        nonlocal changes
        s2, n = re.subn(pattern, repl, s)
        changes += n
        return s2

    # --- macro *definitions* first (the use-site renames would rewrite them) ---
    text = sub(r"`define\s+(?:TAG|TAGI)\s+63:12",
               "`define TAG ADDR_WIDTH-1 : 5+INDEX_WIDTH", text)
    text = sub(r"`define\s+(?:INDEX|INDEXI)\s+11:5",
               f"`define {idx} 5 +: INDEX_WIDTH", text)
    text = sub(r"`define\s+BLOCK_OFFSETI?\s+(4:[23])",
               lambda m: f"`define {blk} {m.group(1)}", text)
    text = sub(r"`define\s+BYTE_OFFSETI?\s+([12]:0)",
               lambda m: f"`define {byt} {m.group(1)}", text)
    text = sub(r"`define\s+OFFSETI\s+5", "`define OFFSET 5", text)

    # --- explanatory header above the first `define ---
    header = HEADER[role].replace("\n", nl)
    m = re.search(r"^`define ", text, re.M)
    if m is None:
        raise AssertionError("no `define block to anchor the header")
    text = text[:m.start()] + header + text[m.start():]
    changes += 1

    # --- use-site renames (I-suffixed first: `INDEXI starts with `INDEX) ---
    text = sub(r"`TAGI\b", "`TAG", text)
    text = sub(r"`INDEXI\b", f"`{idx}", text)
    text = sub(r"`BLOCK_OFFSETI\b", f"`{blk}", text)
    text = sub(r"`BYTE_OFFSETI\b", f"`{byt}", text)
    text = sub(r"`OFFSETI\b", "`OFFSET", text)
    text = sub(r"`INDEX\b", f"`{idx}", text)
    text = sub(r"`BLOCK_OFFSET\b", f"`{blk}", text)
    text = sub(r"`BYTE_OFFSET\b", f"`{byt}", text)

    if role == "controller":
        anchor = "localparam CACHE_DEPTH = 2**INDEX_WIDTH ;"
        if anchor not in text:
            raise AssertionError("no CACHE_DEPTH anchor")
        block = (
            f"{nl}// Tag storage width follows the index split (not the TAG_WIDTH parameter), so{nl}"
            f"// a stale TAG_WIDTH cannot silently truncate the tag compare; it is kept for{nl}"
            f"// interface compatibility and checked below in simulation.{nl}"
            f"localparam TAG_W = ADDR_WIDTH - 5 - INDEX_WIDTH ;{nl}"
            f"`ifndef SYNTHESIS{nl}"
            f"initial if (TAG_WIDTH != TAG_W){nl}"
            f'    $error("{kind} TAG_WIDTH=%0d but the index leaves %0d tag bits", TAG_WIDTH, TAG_W);{nl}'
            f"`endif"
        )
        text = text.replace(anchor, anchor + nl + block, 1)
        changes += 1
        # tag array width from the split
        text = sub(r"(logic\s*\[[^\]\n]*?)TAG_WIDTH(\s*-\s*1[^\]\n]*\]\s*TAG_MEM)",
                   r"\1TAG_W\2", text)

    if role == "memory":
        text = sub(r"11\s*-:\s*INDEX_WIDTH", "5 +: INDEX_WIDTH", text)

    if role == "top":
        # Remove the stale TAG_WIDTH default and re-declare it AFTER ADDR_WIDTH
        # so the derived expression never forward-references a later parameter.
        lines = text.split(nl)
        out, dropped, inserted = [], False, False
        for line in lines:
            if re.match(r"^[ \t]*parameter\s+TAG_WIDTH\s*=\s*\d+,\s*$", line):
                dropped = True
                continue
            out.append(line)
            if not inserted and re.match(r"^[ \t]*parameter\s+ADDR_WIDTH\s*=\s*64,\s*$", line):
                indent = re.match(r"^([ \t]*)", line).group(1)
                out.append(f"{indent}parameter TAG_WIDTH         = ADDR_WIDTH - 5 - INDEX_WIDTH,")
                inserted = True
        if not (dropped and inserted):
            raise AssertionError("TAG_WIDTH/ADDR_WIDTH default lines not found")
        text = nl.join(out)
        changes += 2
        # pass the width down to controller and memory
        text = sub(r"#\(\.TAG_WIDTH\(TAG_WIDTH\)\)",
                   "#(.INDEX_WIDTH(INDEX_WIDTH), .TAG_WIDTH(TAG_WIDTH))", text)

    return text, changes


def apply(path: Path, kind: str, role: str, check: bool) -> int:
    raw = path.read_bytes().decode("latin-1")
    text, n = transform(raw, kind, role)
    if check:
        print(f"[check] {path.relative_to(ROOT)}: {n} edits")
        return n
    if text == raw:
        raise AssertionError(f"{path}: transform produced no change")
    path.write_bytes(text.encode("latin-1"))
    print(f"[edit ] {path.relative_to(ROOT)}: {n} edits")
    return n


def core_tops(check: bool) -> None:
    rtl = ROOT / "rv64imac/RTL/riscv_core_top.sv"
    fpga = ROOT / "rv64imac/FPGA/src/riscv_core_top.sv"
    bp = ROOT / "rv64imac/RTL/Branch_Predicition/TOP WITH BRANCH PREDICTION/riscv_core_top.sv"

    def patch(path: Path, pairs):
        raw = path.read_bytes().decode("latin-1")
        text = raw
        for old, new in pairs:
            if old not in text:
                raise AssertionError(f"{path}: missing {old!r}")
            text = text.replace(old, new, 1)
        if check:
            print(f"[check] {path.relative_to(ROOT)}: {len(pairs)} edits")
        else:
            path.write_bytes(text.encode("latin-1"))
            print(f"[edit ] {path.relative_to(ROOT)}: {len(pairs)} edits")

    # icache instantiation comes first, then the dcache one
    patch(rtl, [
        (".TAG_WIDTH  (52)", ".TAG_WIDTH  (64 - 5 - ICACHE_INDEX_WIDTH)   // tag bits the index leaves"),
        (".TAG_WIDTH(52)", ".TAG_WIDTH(64 - 5 - DCACHE_INDEX_WIDTH)     // tag bits the index leaves"),
    ])
    patch(fpga, [
        (".TAG_WIDTH  (52)", ".TAG_WIDTH  (64 - 5 - 7)   // tag bits the index leaves (INDEX_WIDTH=7)"),
        (".TAG_WIDTH(52)", ".TAG_WIDTH(64 - 5 - 7)     // tag bits the index leaves (INDEX_WIDTH=7)"),
    ])
    patch(bp, [
        (".TAG_WIDTH(20)", ".TAG_WIDTH(64 - 5 - 7)    // was the stale 20; tag bits the index leaves"),
    ])


def main() -> int:
    check = "--check" in sys.argv
    total = 0
    for rel, kind, role, _tree in FILES:
        total += apply(ROOT / rel, kind, role, check)
    core_tops(check)
    print(f"total edits: {total} (+3 core tops)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
