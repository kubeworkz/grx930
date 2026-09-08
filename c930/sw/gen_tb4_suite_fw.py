#!/usr/bin/env python3
"""
gen_tb4_suite_fw.py -- extract the Test-4 Phase-1 (fw) and Phase-2 (vfw)
firmware word arrays from tb/tb_c930_soc_full.sv and emit them as
little-endian byte hex images for DDR preload (one %2x token per byte,
matching the preload_hex format used by tb_soc4.cc).

The two 111-instruction programs are embedded inline in the SV testbench;
regenerating them from the source keeps the Verilator harness and the
iverilog suite in lockstep.

Usage: python sw/gen_tb4_suite_fw.py
Outputs: sw/tb4_phase1_fw.hex   (fw  -- queue 4 mixed GEMMs, drain, DEADBEEF @0xB300)
         sw/tb4_phase2_fw.hex   (vfw -- read back all C via D-cache, verify, DEADBEEF)
"""
import re
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TB = os.path.join(ROOT, "tb", "tb_c930_soc_full.sv")
OUT1 = os.path.join(ROOT, "sw", "tb4_phase1_fw.hex")
OUT2 = os.path.join(ROOT, "sw", "tb4_phase2_fw.hex")

src = open(TB, encoding="utf-8", errors="replace").read()

# Phase-1 block: "// ---- Phase 1: GEMM firmware ----" .. "// ---- Phase 2"
m1 = re.search(r"// ---- Phase 1: GEMM firmware ----(.*?)// ---- Phase 2", src, re.S)
# Phase-2 block: "// Load Phase 2 verification firmware" .. the trailing
# "// Clear DONE_MAGIC" of Phase 2
m2 = re.search(r"// Load Phase 2 verification firmware(.*?)\n      // Clear DONE_MAGIC", src, re.S)
assert m1 and m2, "could not locate Phase 1 / Phase 2 firmware blocks"

WORD = re.compile(r"\b(?:v?fw)\[\s*(\d+)\]\s*=\s*32'h([0-9A-Fa-f]{8})\s*;")


def extract(blk, arrname):
    """Return list of (idx, word32) for array 'arrname' appearing in blk."""
    pat = re.compile(r"\b" + re.escape(arrname) + r"\[\s*(\d+)\]\s*=\s*32'h([0-9A-Fa-f]{8})\s*;")
    hits = [(int(i), int(w, 16)) for i, w in pat.findall(blk)]
    # Deduplicate by index, keep last (the SV assigns each index once).
    d = {}
    for i, w in hits:
        d[i] = w
    return d


fw = extract(m1.group(1), "fw")
vfw = extract(m2.group(1), "vfw")

# Sanity: contiguous 0..110 with no gaps.
def check(arr, name, expect_n=111):
    missing = [i for i in range(expect_n) if i not in arr]
    extra = [i for i in arr if i >= expect_n]
    assert not missing, f"{name}: missing indices {missing[:8]}"
    assert not extra, f"{name}: extra indices {extra[:8]}"
    return [arr[i] for i in range(expect_n)]


fw_words = check(fw, "fw")
vfw_words = check(vfw, "vfw")


def emit(words, path):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for w in words:
            # little-endian byte order, matching ddr_write_byte writes in the SV TB
            f.write(f"{w & 0xFF:02x} {(w >> 8) & 0xFF:02x} {(w >> 16) & 0xFF:02x} {(w >> 24) & 0xFF:02x}\n")
    print(f"wrote {path} ({len(words)} words, {len(words)*4} bytes)")


emit(fw_words, OUT1)
emit(vfw_words, OUT2)
print("OK")
