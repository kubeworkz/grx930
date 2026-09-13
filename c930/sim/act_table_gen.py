#!/usr/bin/env python3
"""
act_table_gen.py -- transfer tables for the NPU activation stage, S_ACT.

Design: c930/doc/npu_act_stage_design_note.md.  This is step 2 of its §7, the
generator the RTL and the C reference both consume.

Physics.  One chi(2) activation unit, type-I SHG TE00(w) -> TM00(2w), integrated
with the coupled-mode equations

    dA/dz = -(a_ff/2) A - i kappa conj(A) B exp(-i dbeta z)
    dB/dz = -(a_sh/2) B - i kappa A^2      exp(+i dbeta z)

where |A|^2 and |B|^2 are the fundamental and second-harmonic powers in watts
and a_ff, a_sh are power loss coefficients.  Lossless and phase matched this is
P_ff = P sech^2(kappa sqrt(P) L), P_sh = P tanh^2(kappa sqrt(P) L), which
--selftest checks.  The integrator and the knee definition are ported from
grxcp docs/designs/pta_tpaqcn_measured.py, which reproduces the energies in
grxcp docs/designs/pta_tpaqcn_review.md; the presets are that review's design
points, and --selftest checks their knees against it.

Table format -- the contract with the RTL and the C reference (note §3), with
S = --seg-bits (default 10) and F = 24 - S:

    x      signed 24-bit table input, [-2^23, 2^23)
    y[i]   2^S + 1 signed 24-bit breakpoints at x_i = -2^23 + i * 2^F
    eval   u = x + 2^23                                   0 .. 2^24-1
           i = u >> F                                     0 .. 2^S - 1
           f = u & (2^F - 1)
           y = y[i] + (((y[i+1] - y[i]) * f) >> F)        arithmetic shift, floor

    At the default, 1025 breakpoints, F = 14: y[i+1] - y[i] needs 25 bits, so
    the interpolation is one DSP48 multiply with the pre-adder forming the
    difference.  y is in x's units: power / P_fs * 2^23 for a power table,
    amplitude / sqrt(P_fs) * 2^23 for an amplitude table.  The unit is passive,
    so its output never exceeds full scale.  Breakpoints round as floor(v + 0.5)
    and saturate to 24 bits.

    kappa sets only the watt scale.  With full scale tied to the knee, two
    design points that differ only in kappa give identical breakpoints; the
    shape depends on loss x length and dbeta x length, and kappa reaches the
    experiment only through the photon count at the knee.

Encodings:

    power      C is optical power.  Negative sums clamp to zero: y = 0, x < 0.
    amplitude  C is field amplitude, P = x^2.  The fundamental keeps its sign
               (an odd curve); the second harmonic does not (even, y >= 0).

Shot-noise port values (note §3, "Noise"), with n the photons at the knee:

    power      sigma = k * isqrt(|x|),   k = sqrt(x_knee / n)
    amplitude  sigma = k * 2^12,         sigma = x_knee / (2 sqrt(n))
               (constant sigma: the square root bypassed to 2^12)
    i_act_k_shot = floor(k * 256 + 0.5), Q8.8

Outputs, in c930/build/act_tables/ by default:

    <name>.hex    $readmemh: a // header, then 2^S + 1 lines of 6 hex digits
    <name>.json   design point, knee, interpolation error, k_shot values

Standard library only:

    python3 c930/sim/act_table_gen.py --selftest
    python3 c930/sim/act_table_gen.py --all
    python3 c930/sim/act_table_gen.py --preset c4-5db-6mm --output ff --encoding power
    python3 c930/sim/act_table_gen.py --kappa 96.3 --length-mm 2 --loss-db 20 --dbeta 2000
    python3 c930/sim/act_table_gen.py --identity
"""
import argparse
import cmath
import json
import math
import os
import sys

# ---- table format ------------------------------------------------------------
XW = 24
FULL = 1 << (XW - 1)                      # 2^23: table full scale
X_MIN = -FULL
X_MAX = FULL - 1
ISQRT_BYPASS = 1 << 12                    # sigma scale when the root is bypassed
KSHOT_MAX = (1 << 16) - 1                 # i_act_k_shot, Q8.8
SIGMA_RATIO_LIMIT = 0.25                  # table error, as a fraction of sigma

# The segment count is a parameter of the format, shared with the RTL.  Chord
# error falls as 1/segments^2, and --compare-seg-bits measures it against the
# shot noise each preset carries at the knee.  64 segments are up to 17x too
# coarse and 256 still fail the as-built unit at a 1 ps clock; 1024 stay under
# SIGMA_RATIO_LIMIT for every preset at every clock, worst 0.08 of sigma, for
# the price of one BRAM36 of breakpoints instead of a BRAM18.
SEG_BITS = SEGMENTS = FRAC_BITS = BREAKPOINTS = 0


def set_seg_bits(bits):
    global SEG_BITS, SEGMENTS, FRAC_BITS, BREAKPOINTS
    SEG_BITS = bits
    SEGMENTS = 1 << bits
    FRAC_BITS = XW - bits                 # 14 at 1024 segments: a 25x14 multiply
    BREAKPOINTS = SEGMENTS + 1


DEFAULT_SEG_BITS = 10
set_seg_bits(DEFAULT_SEG_BITS)

# ---- physics -----------------------------------------------------------------
C0 = 299792458.0
E_PHOTON = 6.62607015e-34 * C0 / 1550e-9  # J
NP_DB = 10 * math.log10(math.e)           # dB per neper, power
DEFAULT_STEPS = 1000


def loss_factor(alpha_db_cm, L_cm):
    """Undepleted SH power with equal loss at both wavelengths, over lossless."""
    x = alpha_db_cm / NP_DB * L_cm / 2
    return (math.exp(-x) * (1 - math.exp(-x)) / x) ** 2


# The measured device, Sci. Adv. 12, eaeg3170 (2026): 29 %/W/cm^2 at 1.7 mm and
# 20 dB/cm.  Loss removed exactly as pta_tpaqcn_measured.py removes it.
ETA0 = 0.29 / loss_factor(20.0, 0.17)     # /W/cm^2, lossless
KAPPA0 = math.sqrt(ETA0 * 1e4)            # W^-1/2 m^-1
KAPPA_C4 = KAPPA0 * 16.0 / 8.1            # compound 4: chi_31 16 against 8.1 pm/V
KAPPA_TFLN = math.sqrt(50.0 * 1e4)        # ~5000 %/W/cm^2, PPLN on thin-film LN

# name: (kappa, L mm, loss_ff dB/cm, loss_sh dB/cm, review knee W, description)
PRESETS = {
    'tpaqcn-built-2mm': (KAPPA0, 2.0, 20.0, 20.0, 32.6,
                         "TPA-QCN as built, 2 mm (review 4.4)"),
    'tpaqcn-5db-6mm':   (KAPPA0, 6.0, 5.0, 5.0, 3.26,
                         "TPA-QCN, leakage removed, 3 dB budget (review 4.4)"),
    'c4-5db-6mm':       (KAPPA_C4, 6.0, 5.0, 5.0, 0.835,
                         "compound 4, leakage removed, 6 mm (review 4.4)"),
    'tfln-1cm':         (KAPPA_TFLN, 10.0, 0.0, 0.0, 0.0155,
                         "TFLN-class, 1 cm, no loss (review 4.5)"),
}


# ---------------------------------------------------------------------------
# Coupled-mode integration
# ---------------------------------------------------------------------------

def solve(P, kappa, L_m, a_ff, a_sh, dbeta=0.0, steps=DEFAULT_STEPS,
          force_complex=False):
    """
    (P_ff, P_sh) at z = L for input power P, by RK4.

    Phase matched, A stays real and B = -i b with b real, so the pair reduces
    to two real equations -- the form pta_tpaqcn_measured.py integrates:
        a' = -(a_ff/2) a - kappa a b,     b' = -(a_sh/2) b + kappa a^2
    A mismatch needs the complex form.  force_complex exists so --selftest can
    check the two against each other.
    """
    if P <= 0.0:
        return 0.0, 0.0
    ha, hb = 0.5 * a_ff, 0.5 * a_sh
    # At least eight steps per radian of whichever phase is faster, the
    # nonlinear one or the mismatch.  The presets never come near this -- a
    # table spans a few radians -- but a mismatched unit's knee can sit at
    # hundreds of watts, where a fixed step count would silently lose accuracy.
    steps = max(steps, int(max(kappa * math.sqrt(P), abs(dbeta)) * L_m * 8) + 1)

    if dbeta == 0.0 and not force_complex:
        h = L_m / steps
        a, b = math.sqrt(P), 0.0
        for _ in range(steps):
            k1a = -ha * a - kappa * a * b
            k1b = -hb * b + kappa * a * a
            a2, b2 = a + 0.5 * h * k1a, b + 0.5 * h * k1b
            k2a = -ha * a2 - kappa * a2 * b2
            k2b = -hb * b2 + kappa * a2 * a2
            a3, b3 = a + 0.5 * h * k2a, b + 0.5 * h * k2b
            k3a = -ha * a3 - kappa * a3 * b3
            k3b = -hb * b3 + kappa * a3 * a3
            a4, b4 = a + h * k3a, b + h * k3b
            k4a = -ha * a4 - kappa * a4 * b4
            k4b = -hb * b4 + kappa * a4 * a4
            a += h / 6 * (k1a + 2 * k2a + 2 * k3a + k4a)
            b += h / 6 * (k1b + 2 * k2b + 2 * k3b + k4b)
        return a * a, b * b

    h = L_m / steps
    step_phase = cmath.exp(1j * dbeta * h / 2)       # exp(i dbeta h/2)
    A, B = complex(math.sqrt(P), 0.0), 0j
    e = 1 + 0j                                       # exp(i dbeta z)

    def deriv(A, B, e):
        return (-ha * A - 1j * kappa * A.conjugate() * B * e.conjugate(),
                -hb * B - 1j * kappa * A * A * e)

    for _ in range(steps):
        e_mid = e * step_phase
        e_end = e_mid * step_phase
        k1A, k1B = deriv(A, B, e)
        k2A, k2B = deriv(A + 0.5 * h * k1A, B + 0.5 * h * k1B, e_mid)
        k3A, k3B = deriv(A + 0.5 * h * k2A, B + 0.5 * h * k2B, e_mid)
        k4A, k4B = deriv(A + h * k3A, B + h * k3B, e_end)
        A += h / 6 * (k1A + 2 * k2A + 2 * k3A + k4A)
        B += h / 6 * (k1B + 2 * k2B + 2 * k3B + k4B)
        e = e_end
    return abs(A) ** 2, abs(B) ** 2


def knee_power(kappa, L_m, a_ff, a_sh, dbeta=0.0, steps=DEFAULT_STEPS):
    """
    The review's knee: the lowest input power at which half the fundamental
    has converted, with its linear loss divided out.  math.inf if conversion
    never reaches one half below 1e7 W.

    Lowest, because a mismatch makes conversion rise and fall with power, so
    more than one power can convert half.  A geometric scan brackets the first
    crossing and bisection refines it; phase matched, conversion is monotone and
    the scan changes nothing.
    """
    linear = math.exp(-a_ff * L_m)

    def converted(P):
        P_ff, _ = solve(P, kappa, L_m, a_ff, a_sh, dbeta, steps)
        return 1.0 - P_ff / (P * linear)

    P0 = (0.8814 / (kappa * L_m)) ** 2          # lossless, phase-matched knee
    lo, hi = 0.0, P0 * 1e-2
    while converted(hi) < 0.5:
        lo, hi = hi, hi * 1.25
        if hi > 1e7:
            return math.inf
    if lo == 0.0:
        lo = hi * 1e-6
    while hi / lo > 1.000000001:
        mid = math.sqrt(lo * hi)
        if converted(mid) < 0.5:
            lo = mid
        else:
            hi = mid
    return math.sqrt(lo * hi)


# ---------------------------------------------------------------------------
# Fixed point
# ---------------------------------------------------------------------------

def sat24(v):
    return X_MIN if v < X_MIN else X_MAX if v > X_MAX else v


def round_half_up(v):
    return int(math.floor(v + 0.5))


def breakpoint_x(i):
    """x of breakpoint i.  x_64 = 2^23 lies one past the 24-bit range."""
    return X_MIN + (i << FRAC_BITS)


def pwl(y, x):
    """The evaluation rule the RTL and the C reference implement, bit for bit."""
    u = x - X_MIN
    i = u >> FRAC_BITS
    f = u & ((1 << FRAC_BITS) - 1)
    return y[i] + (((y[i + 1] - y[i]) * f) >> FRAC_BITS)


class XorShift32:
    """The operand generator of sim/tb_core_verilator.cc: shifts 13, 17, 5."""

    def __init__(self, seed=0xACE1):
        self.s = seed & 0xFFFFFFFF

    def next(self):
        s = self.s
        s ^= (s << 13) & 0xFFFFFFFF
        s ^= s >> 17
        s ^= (s << 5) & 0xFFFFFFFF
        self.s = s
        return s


# ---------------------------------------------------------------------------
# A design point and its tables
# ---------------------------------------------------------------------------

class DesignPoint:
    """One activation unit.  Solves are cached, so outputs and encodings share them."""

    def __init__(self, name, kappa, L_mm, loss_ff_db, loss_sh_db, dbeta=0.0,
                 steps=DEFAULT_STEPS, description=""):
        self.name = name
        self.kappa = kappa
        self.L_mm = L_mm
        self.L_m = L_mm * 1e-3
        self.loss_ff_db = loss_ff_db
        self.loss_sh_db = loss_sh_db
        self.a_ff = loss_ff_db * 100 / NP_DB         # 1/m
        self.a_sh = loss_sh_db * 100 / NP_DB
        self.dbeta = dbeta
        self.steps = steps
        self.description = description
        self._cache = {}
        # Rounded to the six significant digits the JSON records, and every
        # breakpoint is computed from this value.  A table is then a function of
        # its own metadata: a change in how the knee is searched for, which
        # moves the seventh digit, cannot move a breakpoint by an LSB.
        exact = knee_power(kappa, self.L_m, self.a_ff, self.a_sh, dbeta, steps)
        self.P_knee = exact if math.isinf(exact) else float(f"{exact:.6g}")

    def outputs(self, P):
        if P not in self._cache:
            self._cache[P] = solve(P, self.kappa, self.L_m, self.a_ff, self.a_sh,
                                   self.dbeta, self.steps)
        return self._cache[P]


class Table:
    def __init__(self, dp, output, encoding, P_fs):
        assert output in ('ff', 'sh') and encoding in ('power', 'amplitude')
        self.dp, self.output, self.encoding, self.P_fs = dp, output, encoding, P_fs
        self.y = [sat24(round_half_up(self.exact(breakpoint_x(i))))
                  for i in range(BREAKPOINTS)]

    def exact(self, x):
        """The continuous curve, in table units, at table input x."""
        if self.encoding == 'power':
            if x <= 0:
                return 0.0
            P = x / FULL * self.P_fs
        else:
            P = (abs(x) / FULL) ** 2 * self.P_fs
        P_ff, P_sh = self.dp.outputs(P)
        P_out = P_ff if self.output == 'ff' else P_sh
        if self.encoding == 'power':
            return P_out / self.P_fs * FULL
        amp = math.sqrt(P_out / self.P_fs) * FULL
        return -amp if (self.output == 'ff' and x < 0) else amp

    def x_knee(self):
        if math.isinf(self.dp.P_knee):
            return math.inf
        r = self.dp.P_knee / self.P_fs
        return r * FULL if self.encoding == 'power' else math.sqrt(r) * FULL

    def error(self):
        """
        PWL against the curve, about 1024 points: each segment sampled at an
        even number of evenly spaced points, which always includes its
        midpoint, where a quadratic's chord error peaks.  Plus the top of range.
        """
        per = max(2, 1024 // SEGMENTS)
        step = (1 << FRAC_BITS) // per
        xs = [breakpoint_x(i) + k * step
              for i in range(SEGMENTS) for k in range(per)] + [X_MAX]
        worst, worst_x, sq, n = 0.0, 0, 0.0, 0
        xk = self.x_knee()
        op_worst = 0.0
        for x in xs:
            e = pwl(self.y, x) - self.exact(x)
            sq += e * e
            n += 1
            if abs(e) > abs(worst):
                worst, worst_x = e, x
            if not math.isinf(xk) and abs(x) <= 2 * xk:
                op_worst = max(op_worst, abs(e))
        return {
            'max_abs_lsb': round(abs(worst), 3),
            'max_abs_fraction_of_full_scale': float(f"{abs(worst) / FULL:.3e}"),
            'rms_lsb': round(math.sqrt(sq / n), 3),
            'worst_at_x_over_knee': (None if math.isinf(xk)
                                     else round(worst_x / xk, 4)),
            'max_abs_lsb_within_2_knees': round(op_worst, 3),
            'points_checked': n,
        }

    def k_shot(self, n, table_error_lsb):
        """
        Port value for n photons at the knee, and the check that decides whether
        this table is accurate enough to study that noise: its interpolation
        error near the operating point, as a fraction of sigma at the knee.
        """
        xk = self.x_knee()
        if self.encoding == 'power':
            k = math.sqrt(xk / n)
            unit = math.sqrt(xk)                     # isqrt(|x|) at the knee
        else:
            k = xk / (2 * math.sqrt(n)) / ISQRT_BYPASS
            unit = ISQRT_BYPASS
        q = round_half_up(k * 256)
        sigma_exact = k * unit
        sigma_real = min(q, KSHOT_MAX) / 256 * unit
        ratio = table_error_lsb / sigma_exact
        return {
            'photons_at_knee': float(f"{n:.4g}"),
            'i_act_k_shot': min(q, KSHOT_MAX),
            'overflow': q > KSHOT_MAX,
            'sigma_at_knee_lsb': round(sigma_exact, 2),
            'sigma_quantisation_error': float(f"{sigma_real / sigma_exact - 1:.2e}"),
            'table_error_over_sigma': round(ratio, 4),
            'table_accurate_enough': ratio <= SIGMA_RATIO_LIMIT,
        }


def table_name(dp, output, encoding):
    name = f"act_{dp.name}_{output}_{encoding}"
    if dp.dbeta:
        name += f"_db{dp.dbeta:g}"
    return name


def write_table(table, out_dir, photons, pulses_s, fs_knees, quiet):
    dp = table.dp
    name = table_name(dp, table.output, table.encoding)
    os.makedirs(out_dir, exist_ok=True)

    header = (f"// {name}: {dp.description or 'custom design point'}\n"
              f"// kappa {dp.kappa:.4g} W^-1/2 m^-1, L {dp.L_mm:g} mm,"
              f" loss {dp.loss_ff_db:g}/{dp.loss_sh_db:g} dB/cm,"
              f" dbeta {dp.dbeta:g} /m, P_fs {table.P_fs:.6g} W\n"
              f"// {BREAKPOINTS} x {XW}-bit signed, y[i] at x = -2^23 + i*2^{FRAC_BITS};"
              f" generated by c930/sim/act_table_gen.py\n")
    with open(os.path.join(out_dir, name + ".hex"), "w", newline="\n") as fh:
        fh.write(header)
        for v in table.y:
            fh.write(f"{v & 0xFFFFFF:06x}\n")

    xk = table.x_knee()
    err = table.error()
    # Photon counts: the sweep, plus what the knee carries at the two pulsed
    # clocks of review 4.5.  The 10 ps clock is priced in energy below but not
    # swept: the review already rules all-optical out there.
    counts = (sorted(set(photons) | {dp.P_knee * t / E_PHOTON
                                     for t in pulses_s if t < 10e-12})
              if not math.isinf(xk) else [])
    meta = {
        'name': name,
        'description': dp.description,
        'design_point': {
            'kappa_W-1/2_m-1': round(dp.kappa, 4),
            'length_mm': dp.L_mm,
            'loss_ff_dB_per_cm': dp.loss_ff_db,
            'loss_sh_dB_per_cm': dp.loss_sh_db,
            'dbeta_per_m': dp.dbeta,
            'rk4_steps': dp.steps,
        },
        'table': {
            'output': table.output,
            'encoding': table.encoding,
            'full_scale_W': float(f"{table.P_fs:.6g}"),
            'full_scale_knees': fs_knees,
            'segments': SEGMENTS,
            'breakpoints': BREAKPOINTS,
            'breakpoint_bits': XW,
            'segment_index_bits': SEG_BITS,
            'segment_frac_bits': FRAC_BITS,
            'saturated_breakpoints': sum(1 for i, v in enumerate(table.y)
                                         if v in (X_MIN, X_MAX)
                                         and abs(table.exact(breakpoint_x(i))) >= X_MAX),
        },
        'knee': {
            'P_knee_W': None if math.isinf(dp.P_knee) else float(f"{dp.P_knee:.6g}"),
            'x_knee_table_units': None if math.isinf(xk) else round(xk, 1),
            # k_shot is referred to the knee.  With --fs-watts the knee can lie
            # past full scale, where those values describe a point the table
            # never reaches.
            'inside_table': (not math.isinf(xk)) and xk <= X_MAX,
            'energy_J_at_pulse_s': ({} if math.isinf(dp.P_knee) else
                                    {f"{t:.0e}": float(f"{dp.P_knee * t:.4g}")
                                     for t in pulses_s}),
        },
        'linear_transmission': {
            'ff': round(math.exp(-dp.a_ff * dp.L_m), 6),
            'sh': round(math.exp(-dp.a_sh * dp.L_m), 6),
        },
        'interpolation_error': err,
        'k_shot': [table.k_shot(n, err['max_abs_lsb_within_2_knees']) for n in counts],
    }
    with open(os.path.join(out_dir, name + ".json"), "w", newline="\n") as fh:
        json.dump(meta, fh, indent=2, sort_keys=True)
        fh.write("\n")

    worst = max((k['table_error_over_sigma'] for k in meta['k_shot']), default=0.0)
    if not quiet:
        knee = meta['knee']['P_knee_W']
        print(f"  {name:<40} knee {knee if knee is not None else 'none':>9} W"
              f"  err {err['max_abs_lsb_within_2_knees']:>8} LSB"
              f"  worst err/sigma {worst:6.3f}"
              f"{'' if worst <= SIGMA_RATIO_LIMIT else '  TOO COARSE'}"
              f"{'' if meta['knee']['inside_table'] else '  KNEE PAST FULL SCALE'}")
    return meta


def write_identity(out_dir, quiet):
    """y = x.  Exact below the top segment; the top breakpoint saturates."""
    os.makedirs(out_dir, exist_ok=True)
    y = [sat24(breakpoint_x(i)) for i in range(BREAKPOINTS)]
    with open(os.path.join(out_dir, "act_identity.hex"), "w", newline="\n") as fh:
        fh.write("// act_identity: y = x, for gate A1.  Exact for"
                 f" x < 2^23 - 2^{FRAC_BITS} = {FULL - (1 << FRAC_BITS)};"
                 " the top segment is low by at most 1 LSB.\n")
        for v in y:
            fh.write(f"{v & 0xFFFFFF:06x}\n")
    if not quiet:
        print(f"  act_identity: exact for x in [{X_MIN}, {FULL - (1 << FRAC_BITS)}),"
              " top segment within 1 LSB")
    return y


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

def selftest():
    failures = []

    def check(label, ok, detail):
        print(f"  {'PASS' if ok else 'FAIL'}  {label}: {detail}")
        if not ok:
            failures.append(label)

    print("physics")
    kappa, L = 500.0, 5e-3
    worst = 0.0
    for P in (0.01, 0.1, 1.0):
        P_ff, P_sh = solve(P, kappa, L, 0.0, 0.0)
        x = kappa * math.sqrt(P) * L
        worst = max(worst, abs(P_ff / (P / math.cosh(x) ** 2) - 1),
                    abs(P_sh / (P * math.tanh(x) ** 2) - 1))
    check("lossless, phase matched, against sech^2 / tanh^2", worst < 1e-8,
          f"worst relative error {worst:.1e}")

    worst = 0.0
    for P in (0.05, 0.5, 5.0):
        r = solve(P, 96.3, 2e-3, 460.5, 460.5)
        c = solve(P, 96.3, 2e-3, 460.5, 460.5, force_complex=True)
        worst = max(worst, abs(r[0] - c[0]) / P, abs(r[1] - c[1]) / P)
    check("complex path equals real path at dbeta = 0", worst < 1e-10,
          f"worst difference {worst:.1e} of input")

    worst = 0.0
    for P in (0.1, 1.0, 10.0):
        P_ff, P_sh = solve(P, 96.3, 6e-3, 0.0, 0.0, dbeta=3000.0)
        worst = max(worst, abs((P_ff + P_sh) / P - 1))
    check("lossless with a mismatch conserves power", worst < 1e-8,
          f"worst relative error {worst:.1e}")

    print("knees, against grxcp pta_tpaqcn_review.md")
    P = knee_power(121.0, 2e-3, 15.0 * 100 / NP_DB, 10.0 * 100 / NP_DB)
    check("the review's own model point, kappa 121, 2 mm, 15/10 dB/cm",
          abs(P / 17.78 - 1) < 0.005, f"{P:.4g} W, review 17.78 W (178 pJ)")
    for name, (kappa, L_mm, lff, lsh, expect, _) in PRESETS.items():
        P = knee_power(kappa, L_mm * 1e-3, lff * 100 / NP_DB, lsh * 100 / NP_DB)
        check(f"preset {name}", abs(P / expect - 1) < 0.01,
              f"{P:.4g} W, review {expect:g} W")

    print("fixed point")
    default_bits = SEG_BITS
    for bits in sorted({6, 8, default_bits}):
        set_seg_bits(bits)
        y = [sat24(breakpoint_x(i)) for i in range(BREAKPOINTS)]
        rng = XorShift32()
        top = FULL - (1 << FRAC_BITS)
        xs = [breakpoint_x(i) + d for i in range(SEGMENTS) for d in (0, 1, -1)
              if X_MIN <= breakpoint_x(i) + d < top]
        xs += [X_MIN + (rng.next() % (top - X_MIN)) for _ in range(100000)]
        bad = sum(1 for x in xs if pwl(y, x) != x)
        check(f"identity, {SEGMENTS} segments: exact below the top segment",
              bad == 0, f"{bad} mismatches in {len(xs)} points")
        top_err = max(abs(pwl(y, x) - x) for x in range(top, X_MAX + 1, 97))
        check(f"identity, {SEGMENTS} segments: top segment", top_err <= 1,
              f"max error {top_err} LSB")
    set_seg_bits(default_bits)
    check("INT8 sums fit below the identity's top segment",
          256 * 128 * 128 < FULL - (1 << FRAC_BITS),
          f"K=256 x 128 x 128 = {256 * 128 * 128} < {FULL - (1 << FRAC_BITS)}")

    dp = DesignPoint('selftest', KAPPA_C4, 6.0, 5.0, 5.0, steps=400)
    for output in ('ff', 'sh'):
        t = Table(dp, output, 'power', 4 * dp.P_knee)
        passive = all(t.y[i] <= max(breakpoint_x(i), 0) + 1
                      for i in range(BREAKPOINTS - 1))
        check(f"power table, {output}: output never exceeds input", passive,
              "passive unit")
    a = Table(dp, 'ff', 'amplitude', 4 * dp.P_knee)
    b = Table(dp, 'ff', 'amplitude', 4 * dp.P_knee)
    odd = all(a.y[i] == -a.y[BREAKPOINTS - 1 - i] for i in range(1, SEGMENTS // 2))
    check("amplitude ff table is odd about zero", odd, "sign preserved")
    check("deterministic", a.y == b.y, "two builds, identical breakpoints")

    print(f"\n{'all passed' if not failures else f'{len(failures)} FAILED'}")
    return 0 if not failures else 1


def compare_seg_bits(steps):
    """
    The evidence for the default segment count.  For the three distinct curve
    shapes among the presets -- 4 dB, 3 dB and no loss; kappa alone only sets
    the watt scale, so the two 6 mm presets give identical tables -- report the
    worst interpolation error within two knees against sigma at the knee for
    10^6 photons and for the photon counts of a 1 ps and a 100 fs pulse.
    """
    shapes = ('tpaqcn-built-2mm', 'c4-5db-6mm', 'tfln-1cm')
    print(f"  {'preset':<18}{'encoding':<11}{'segments':>9}{'err LSB':>10}"
          f"{'/sigma 1e6':>12}{'/sigma 1ps':>12}{'/sigma 100fs':>14}")
    default_bits = SEG_BITS
    for name in shapes:
        kappa, L_mm, lff, lsh, _, desc = PRESETS[name]
        dp = DesignPoint(name, kappa, L_mm, lff, lsh, 0.0, steps, desc)
        counts = (1e6, dp.P_knee * 1e-12 / E_PHOTON, dp.P_knee * 100e-15 / E_PHOTON)
        for encoding in ('power', 'amplitude'):
            for bits in (6, 7, 8, 10):
                set_seg_bits(bits)
                t = Table(dp, 'ff', encoding, 4 * dp.P_knee)
                e = t.error()['max_abs_lsb_within_2_knees']
                ratios = [t.k_shot(n, e)['table_error_over_sigma'] for n in counts]
                print(f"  {name:<18}{encoding:<11}{SEGMENTS:>9}{e:>10.1f}"
                      + "".join(f"{r:>12.3f}" for r in ratios[:2])
                      + f"{ratios[2]:>14.3f}")
    set_seg_bits(default_bits)
    return 0


# ---------------------------------------------------------------------------

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(
        description="Transfer tables for the NPU activation stage (S_ACT).")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--list", action="store_true", help="list presets")
    ap.add_argument("--all", action="store_true",
                    help="every preset x {ff, sh} x {power, amplitude}, plus identity")
    ap.add_argument("--identity", action="store_true", help="y = x, for gate A1")
    ap.add_argument("--preset", choices=sorted(PRESETS))
    ap.add_argument("--kappa", type=float, help="W^-1/2 m^-1")
    ap.add_argument("--length-mm", type=float)
    ap.add_argument("--loss-db", type=float, help="dB/cm at both wavelengths")
    ap.add_argument("--loss-ff-db", type=float)
    ap.add_argument("--loss-sh-db", type=float)
    ap.add_argument("--dbeta", type=float, default=0.0, help="phase mismatch, 1/m")
    ap.add_argument("--output", choices=("ff", "sh"), default="ff")
    ap.add_argument("--encoding", choices=("power", "amplitude"), default="power")
    ap.add_argument("--fs-knees", type=float, default=4.0,
                    help="table full scale as a multiple of the knee power")
    ap.add_argument("--fs-watts", type=float, help="table full scale in watts")
    ap.add_argument("--photons", type=float, nargs="*",
                    default=[1e3, 1e4, 1e5, 1e6], help="photons at the knee")
    ap.add_argument("--steps", type=int, default=DEFAULT_STEPS)
    ap.add_argument("--seg-bits", type=int, default=DEFAULT_SEG_BITS,
                    help="log2 of the segment count; must match the RTL parameter")
    ap.add_argument("--compare-seg-bits", action="store_true",
                    help="interpolation error against sigma for 64..1024 segments")
    ap.add_argument("--out", default=os.path.normpath(
        os.path.join(here, "..", "build", "act_tables")))
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if not 4 <= args.seg_bits <= 12:
        ap.error("--seg-bits must be 4..12")
    set_seg_bits(args.seg_bits)

    if args.selftest:
        return selftest()
    if args.compare_seg_bits:
        return compare_seg_bits(args.steps)
    if args.list:
        for name, (kappa, L_mm, lff, lsh, knee, desc) in PRESETS.items():
            print(f"  {name:<18} kappa {kappa:7.1f}  L {L_mm:4g} mm"
                  f"  loss {lff:g}/{lsh:g} dB/cm  knee {knee:g} W  {desc}")
        return 0

    pulses = (10e-12, 1e-12, 100e-15)     # the clocks of review 4.5

    def build(dp, outputs, encodings):
        if math.isinf(dp.P_knee) and args.fs_watts is None:
            sys.exit(f"{dp.name}: conversion never reaches one half at this"
                     " mismatch, so there is no knee; give --fs-watts")
        P_fs = args.fs_watts if args.fs_watts else args.fs_knees * dp.P_knee
        for output in outputs:
            for encoding in encodings:
                write_table(Table(dp, output, encoding, P_fs), args.out,
                            args.photons, pulses, None if args.fs_watts else
                            args.fs_knees, args.quiet)

    if args.all:
        print(f"writing to {args.out}")
        for name, (kappa, L_mm, lff, lsh, _, desc) in PRESETS.items():
            build(DesignPoint(name, kappa, L_mm, lff, lsh, args.dbeta, args.steps,
                              desc), ("ff", "sh"), ("power", "amplitude"))
        write_identity(args.out, args.quiet)
        return 0

    if args.identity:
        write_identity(args.out, args.quiet)
        return 0

    if args.preset:
        kappa, L_mm, lff, lsh, _, desc = PRESETS[args.preset]
        name = args.preset
    elif args.kappa is not None and args.length_mm is not None:
        kappa, L_mm, desc = args.kappa, args.length_mm, ""
        lff = lsh = args.loss_db if args.loss_db is not None else 0.0
        name = f"k{kappa:g}-L{L_mm:g}mm-{lff:g}db"
    else:
        ap.error("give --preset, or --kappa and --length-mm"
                 " (or --all, --identity, --selftest, --list)")
    if args.loss_ff_db is not None:
        lff = args.loss_ff_db
    if args.loss_sh_db is not None:
        lsh = args.loss_sh_db
    build(DesignPoint(name, kappa, L_mm, lff, lsh, args.dbeta, args.steps, desc),
          (args.output,), (args.encoding,))
    return 0


if __name__ == "__main__":
    sys.exit(main())
