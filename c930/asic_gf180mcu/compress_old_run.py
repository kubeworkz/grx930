#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Compress the OLD campaign run's bulky files in place (run as root inside
the openlane container; host user cannot rewrite the root-owned bind files).
Keeps data: foo.odb -> foo.odb.zst. Only the pre-campaign runs listed in
ROOTS are touched - never the active v8 run (RUN_2026-09-30_23-41-23).
"""
import os
import sys

ROOTS = [
    "/work/openlane2_rtl/runs/RUN_2026-09-22_15-09-48",
    "/work/openlane2_rtl/runs/RUN_2026-09-22_22-57-37",
    "/work/openlane2_rtl/runs/RUN_2026-09-23_01-58-03",
    "/work/openlane2_rtl/runs/RUN_2026-09-23_16-04-17",
    "/work/openlane2_rtl/runs/RUN_2026-09-23_20-00-34",
]
MIN = 10 * 1024 * 1024
SUFFIXES = (".odb", ".guide", ".log", ".def", ".pnl.v")

try:
    import zstandard as zstd
    MODE = "zstd"
except ImportError:
    import gzip
    MODE = "gzip"

def compress(src, dst):
    with open(src, "rb") as fi, open(dst, "wb") as fo:
        if MODE == "zstd":
            zstd.ZstdCompressor(level=10, threads=2).copy_stream(fi, fo)
        else:
            with gzip.GzipFile(fileobj=fo, mode="wb", compresslevel=6) as g:
                while True:
                    chunk = fi.read(1 << 20)
                    if not chunk:
                        break
                    g.write(chunk)

targets = []
for root in ROOTS:
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if name.endswith(SUFFIXES):
                p = os.path.join(dirpath, name)
                try:
                    if os.path.getsize(p) >= MIN:
                        targets.append(p)
                except OSError:
                    pass

print(f"mode={MODE} files={len(targets)}", flush=True)
tin = tout = 0
for src in sorted(targets):
    dst = src + (".zst" if MODE == "zstd" else ".gz")
    try:
        insize = os.path.getsize(src)
        compress(src, dst)
        os.remove(src)
        outsize = os.path.getsize(dst)
        tin += insize
        tout += outsize
        print(f"{insize/1e6:7.0f} -> {outsize/1e6:6.0f} MB  {src}", flush=True)
    except Exception as e:  # keep going; partial reclaim still helps
        print(f"ERR {src}: {e}", flush=True)
        try:
            os.remove(dst)
        except OSError:
            pass

print(f"TOTAL {tin/1e9:.2f} -> {tout/1e9:.2f} GB ({100*tout/max(tin,1):.0f}%)", flush=True)
sys.exit(0)
