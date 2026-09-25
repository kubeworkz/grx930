"""Is the shortened stage 6 the same function as the one in the RTL?

The RTL computes, every cycle, in one combinational cone:

    prod  = y * r                       DSP, r selected by an 8:1 mux on col
    yr    = sat29(prod >>> 12)
    sh    = 24 - adc_bits
    q     = (yr + (1 <<< (sh - 1))) >>> sh
    qc    = clamp(q, -(1 <<< (B-1)), (1 <<< (B-1)) - 1)
    c     = requant ? (qc <<< sh) : yr
    ys    = min(yshift, 32)
    wide  = c <<< ys
    out   = sat32(wide)

Three of those shifts are by a distance derived from configuration, and two of
them cancel: (x >>> s) <<< s is x with its low s bits cleared, which is an AND
with a constant, and a clamp commutes with a monotone left shift.  So:

    t     = (yr + round) & mask         round = 1 <<< (sh-1), mask = ~((1<<sh)-1)
    c     = requant ? clamp(t, lo_s, hi_s) : yr    lo_s = lo <<< sh, hi_s = hi <<< sh
    wide  = c <<< ys
    out   = sat32(wide)

round, mask, lo_s, hi_s and ys all depend only on adc_bits and yshift, which are
sampled at cfg_load, so they become registers and leave the per-element path with
one variable shift instead of three.  This checks the two are the same function,
including the 29-bit wrap the RTL's intermediate width allows.
"""

import random


def s(v, w):
    """Interpret the low w bits of v as two's complement, as the RTL's width does."""
    v &= (1 << w) - 1
    return v - (1 << w) if v >> (w - 1) else v


def asr(v, n):
    """Arithmetic right shift, floor -- what >>> gives on a signed value."""
    return v >> n


def rtl(y, r, adc_bits, yshift, requant):
    prod = s(y * r, 41)
    yr = s(asr(prod, 12), 29)
    sh = s(24 - adc_bits, 5) & 0x1f
    q = s(asr(s(yr + s(1 << (sh - 1), 29), 29), sh), 29)
    hi = s((1 << (adc_bits - 1)) - 1, 29)
    lo = s(-(1 << (adc_bits - 1)), 29)
    if q > hi:
        qc = hi
    elif q < lo:
        qc = lo
    else:
        qc = q
    c = s(qc << sh, 29) if requant else yr
    ys = 32 if yshift > 32 else yshift
    wide = s(c << ys, 64)
    if wide > 0x7fffffff:
        return 0x7fffffff, 1
    if wide < -0x80000000:
        return -0x80000000, 1
    return s(wide, 32), 0


def shortened(y, r, adc_bits, yshift, requant):
    # Registered at cfg_load, once per GEMM.
    sh = s(24 - adc_bits, 5) & 0x1f
    round_r = s(1 << (sh - 1), 29)
    mask_r = s(~((1 << sh) - 1), 29)
    hi_s = s(((1 << (adc_bits - 1)) - 1) << sh, 29)
    lo_s = s((-(1 << (adc_bits - 1))) << sh, 29)
    ys = 32 if yshift > 32 else yshift

    # Per element.
    prod = s(y * r, 41)
    yr = s(asr(prod, 12), 29)
    t = s(s(yr + round_r, 29) & mask_r, 29)
    if t > hi_s:
        tc = hi_s
    elif t < lo_s:
        tc = lo_s
    else:
        tc = t
    c = tc if requant else yr
    wide = s(c << ys, 64)
    if wide > 0x7fffffff:
        return 0x7fffffff, 1
    if wide < -0x80000000:
        return -0x80000000, 1
    return s(wide, 32), 0


def main():
    random.seed(20260924)
    bad = 0
    checked = 0
    edges = [0, 1, -1, 2, -2, (1 << 23) - 1, -(1 << 23),
             (1 << 22), -(1 << 22), (1 << 23) // 3]
    for adc_bits in range(1, 16):
        for yshift in list(range(0, 35)) + [40, 63]:
            for requant in (0, 1):
                ys = [(yv, rv) for yv in edges for rv in (0, 1, 4095, 4096, 65535)]
                ys += [(random.randint(-(1 << 23), (1 << 23) - 1),
                        random.randint(0, 65535)) for _ in range(40)]
                for y, r in ys:
                    a = rtl(y, r, adc_bits, yshift, requant)
                    b = shortened(y, r, adc_bits, yshift, requant)
                    checked += 1
                    if a != b:
                        bad += 1
                        if bad <= 6:
                            print("MISMATCH adc_bits=%d yshift=%d requant=%d "
                                  "y=%d r=%d: rtl=%s shortened=%s"
                                  % (adc_bits, yshift, requant, y, r, a, b))
    print("checked %d combinations, %d mismatches" % (checked, bad))
    return 1 if bad else 0


raise SystemExit(main())
