#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Scan a GDSII stream for coordinates off the 5 nm manufacturing grid.

Walks records linearly; attributes off-grid XY records to (layer, datatype)
and to the enclosing CELL/STRNAME.  dbu is read from the UNITS record.
"""
import struct, sys, collections


def gds_real(b):
    """Decode an 8-byte GDSII real (IBM excess-64), not IEEE -- get this wrong and the
    dbu line below prints 0.000 nm while every count stays perfectly valid (the off-grid
    test is `coord % 5`, which only needs dbu to be 1 nm to mean what it says)."""
    sign = -1 if b[0] & 0x80 else 1
    exp = (b[0] & 0x7F) - 64
    mant = int.from_bytes(b[1:8], "big")
    return sign * mant * 16.0 ** (exp - 14)

def scan(path, limit_cells=12):
    data = open(path, "rb").read()
    n = len(data)
    i = 0
    dbu = None
    cell = "<top>"
    layer = dt = None
    struct_name = None
    off = collections.Counter()      # (layer,dt) -> off-grid coords
    tot = collections.Counter()      # (layer,dt) -> coords
    offcells = collections.Counter()
    cells = collections.Counter()
    total_off = 0
    total_pts = 0
    struct_depth = 0
    cur_struct = None
    pending = False
    while i + 4 <= n:
        rlen, rtype, rkind = struct.unpack(">HBB", data[i:i+4])
        if rlen < 4 or i + rlen > n:
            break
        body = data[i+4:i+rlen]
        if rtype == 0x00 and rkind == 0x02:          # HEADER
            pass
        elif rtype == 0x03 and rkind == 0x05:        # UNITS: 8-byte real x2
            dbu = gds_real(body[8:16]) * 1e9   # dbu in nm
        elif rtype == 0x05 and rkind == 0x02:        # BGNSTR
            struct_depth += 1
            pending = False
        elif rtype == 0x07 and rkind == 0x00:        # ENDSTR
            struct_depth = max(0, struct_depth - 1)
            cur_struct = None
        elif rtype == 0x06 and rkind == 0x06:        # STRNAME
            cur_struct = body.split(b"\0")[0].decode("latin1")
            cells[cur_struct] += 1
        elif rtype == 0x0d and rkind == 0x02:        # LAYER
            layer = struct.unpack(">h", body[:2])[0]
        elif rtype == 0x0e and rkind == 0x02:        # DATATYPE
            dt = struct.unpack(">h", body[:2])[0]
        elif rtype in (0x08, 0x09, 0x2d) and rkind == 0x00:   # BOUNDARY/PATH/BOX
            pending = True
        elif rtype == 0x10 and rkind == 0x03:                # XY
            if not pending:
                i += rlen
                continue
            pending = False
            vals = struct.unpack(">%dh" % (len(body) // 2), body)
            key = (layer, dt)
            curoff = 0
            for k in range(0, len(vals) - 1, 2):
                total_pts += 1
                tot[key] += 1
                if vals[k] % 5 or vals[k+1] % 5:
                    curoff += 1
            total_off += curoff
            off[key] += curoff
            if curoff:
                offcells[cur_struct or "?"] += curoff
        i += rlen
    print("== %s  (%d B)  dbu=%.3f nm  cells=%d" % (path, n, dbu if dbu else -1, len(cells)))
    if dbu and abs(dbu - 1.0) > 1e-6:
        print("   NOTE: dbu is not 1 nm, so 'off the 5 nm grid' below means 'not a multiple"
              " of 5 dbu' -- read it as a grid test only when dbu == 1 nm.")
    print("   XY coordinate pairs: %d   off 5nm grid: %d (%.2f%%)" %
          (total_pts, total_off, 100.0 * total_off / max(1, total_pts)))
    print("   off-grid by layer/datatype (top 10):")
    for (l, d), c in off.most_common(10):
        print("     layer %-5s dt %-4s %8d off of %8d coords" % (l, d, c, tot[(l, d)]))
    print("   cells owning off-grid shapes (top %d):" % limit_cells)
    for c, k in offcells.most_common(limit_cells):
        print("     %-40s %8d" % (c, k))
    print()

for p in sys.argv[1:]:
    try:
        scan(p)
    except Exception as e:
        print("== %s FAILED: %s" % (p, e))
