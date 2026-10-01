#!/usr/bin/env python3
"""A3's sweep: the reset-interval-versus-photons curve.

npu_act_stage_design_note.md section 6, A3. The question is how many all-optical
activations can be chained before a digital reset is needed, as a function of the
photons each activation carries and of fabrication detuning. That number is the
reset interval N, and it bounds everything an all-optical branch could be.

This drives the core bench's `--act chain` once per sweep point and collects the
one line each run prints. It lives in Python because the photon-count-to-k_shot
mapping lives with the physics, in the tables the generator emits: a point's
`i_act_k_shot` is read out of `act_<preset>_<out>_<encoding>.json` rather than
recomputed here, so there is exactly one place that knows it.

The sweep, as A3 specifies it:

    N        in {1, 2, 4, 8, inf}        requantisation interval
    photons  10^3 .. 10^6 at the knee    the main axis
    sigma    in {0, 7, 14} nm            strip-width spread, the detuning draw
    shape    the presets                 loss x length, output, encoding

The shape axis is short on purpose: kappa drops out of a curve's shape, which
depends only on loss x length and mismatch x length, so the four presets span
three loss budgets and no more (design note section 5).

A3 is REPORTED, not gated. The only thing that can fail is the per-layer bitwise
check inside the bench, which says the RTL and the C reference still agree; a
non-zero exit means that, not a bad curve.

Standard library only.  Run from c930/:
    python3 sim/act_chain_sweep.py --quick
    python3 sim/act_chain_sweep.py            # the full sweep
"""
import argparse
import json
import os
import re
import subprocess
import sys

TABLES = os.path.join('build', 'act_tables')
RUNNER = os.path.join('sim', 'build_core_verilator_wsl.sh')
# The default build: no PTM tile, two banks.  A3 measures the activation chain on
# an exact digital MAC -- the tile's own impairments are C1's and explicitly not a
# dependency (design note section 5) -- so the plain core is the right model.
BINARY = 'build/verilator_core/tb_core_verilator'


def wsl_path(win):
    """C:/x -> /mnt/c/x, the conversion build_core_verilator_wsl.sh does."""
    w = win.replace(chr(92), '/')
    if len(w) > 1 and w[1] == ':':
        return '/mnt/' + w[0].lower() + w[2:]
    return w


def build_once(dry):
    """Verilate and compile once.  The runner script rebuilds on every
    invocation, and the full sweep is 240 points, so the sweep drives the binary
    directly after one build rather than paying for 240 of them."""
    cmd = ['bash', RUNNER]
    if dry:
        print('    would build: %s' % ' '.join(cmd))
        return True
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.stderr.write(p.stdout[-4000:] + p.stderr[-4000:])
        return False
    return True

# A3's axes.  `None` is the design note's N = inf: never requantise.
RESETS = (1, 2, 4, 8, None)
SIGMAS = (0.0, 7.0, 14.0)
PHOTONS_FULL = (1e3, 1e4, 1e5, 1e6)
PHOTONS_QUICK = (1e3, 1e6)
# One preset per loss budget, which is all the shape axis can distinguish, plus
# the built device as the anchor.  Both encodings of one of them, because power
# and amplitude are different networks (design note section 8, item 2).
SHAPES_FULL = (
    ('tpaqcn-built-2mm', 'ff', 'power'),
    ('c4-5db-6mm', 'ff', 'power'),
    ('c4-5db-6mm', 'ff', 'amplitude'),
    ('tfln-1cm', 'ff', 'power'),
)
SHAPES_QUICK = (('c4-5db-6mm', 'ff', 'power'),)

RESULT = re.compile(
    r'\[A3\] RESULT cal=(\d) k_shot=(\d+) sigma_nm=([\d.]+) reset=(\S+) '
    r'depth_at_5pct=(\S+) rel_rms_final=([\d.]+)')
# The detuning draw is NUM_COLS = 8 wide, which is a small sample: at sigma 7 the
# depth a chain reaches varied 5x across five seeds (0.056 to 0.284 relative RMS
# at depth 6).  So every sigma > 0 point is run over several seeds and reported
# as a median with its range; a single-seed sigma number is not a measurement.
SEEDS = (1, 2, 3, 4, 5)


def fmt_depth(d, layers):
    """layers + 1 is the sentinel for "never, within the chain's length"."""
    return '-' if d > layers else ('%g' % d)


def median(xs):
    v = sorted(xs)
    n = len(v)
    return v[n // 2] if n % 2 else 0.5 * (v[n // 2 - 1] + v[n // 2])


def table_paths(preset, out, encoding):
    stem = 'act_%s_%s_%s' % (preset, out, encoding)
    return (os.path.join(TABLES, stem + '.hex'),
            os.path.join(TABLES, stem + '.json'))


def k_shot_for(meta, photons):
    """i_act_k_shot at this photon count, from the generator's own table.

    Exact match only. A photon count the generator was not asked for has no
    k_shot, and interpolating one here would put a second copy of the physics in
    a sweep driver -- which is how two copies drift apart.
    """
    for e in meta['k_shot']:
        if abs(e['photons_at_knee'] - photons) < 1e-6:
            if e.get('overflow'):
                return None, 'k_shot overflows at this photon count'
            if not e.get('table_accurate_enough', True):
                return None, 'the generator says the table is not accurate enough here'
            return int(e['i_act_k_shot']), None
    have = ', '.join('%g' % e['photons_at_knee'] for e in meta['k_shot'])
    return None, 'no k_shot for %g photons; the table has %s' % (photons, have)


def run_point(hexpath, k_shot, sigma, reset, amplitude, layers, seed, dry,
              calibrated=False):
    args = ['--act', 'chain', '--table', hexpath.replace(chr(92), '/'),
            '--act-k-shot', str(k_shot), '--act-sigma-nm', '%g' % sigma,
            '--chain-layers', str(layers), '--chain-seed', str(seed)]
    if reset is not None:
        args += ['--chain-reset', str(reset)]
    if amplitude:
        args += ['--act-amplitude']
    if calibrated:
        args += ['--chain-cal']
    inner = "cd '%s' && ./%s %s" % (wsl_path(os.getcwd()), BINARY, ' '.join(args))
    cmd = ['wsl.exe', '-e', 'bash', '-c', inner]
    if dry:
        print('    would run: %s' % inner)
        return None, 0
    p = subprocess.run(cmd, capture_output=True, text=True)
    m, bad = None, 0
    for line in p.stdout.splitlines():
        hit = RESULT.search(line)
        if hit:
            m = hit
        # The bench's own gate: RTL against the C reference, every layer.  A
        # point that fails it is excluded from the curve and reported, which is
        # not the same as the sweep failing.
        g = re.search(r'\[core\] (\d+) FAILURES', line)
        if g:
            bad = int(g.group(1))
    if m is None and p.returncode != 0:
        sys.stderr.write(p.stdout[-2000:] + p.stderr[-2000:])
    return m, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--quick', action='store_true',
                    help='two photon counts and one shape, to check the plumbing')
    ap.add_argument('--layers', type=int, default=16)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--dry-run', action='store_true')
    a = ap.parse_args()

    photons = PHOTONS_QUICK if a.quick else PHOTONS_FULL
    shapes = SHAPES_QUICK if a.quick else SHAPES_FULL

    if not os.path.isdir(TABLES):
        print('no %s: run  python3 sim/act_table_gen.py --all  first' % TABLES,
              file=sys.stderr)
        return 2

    if not build_once(a.dry_run):
        print('the core bench did not build', file=sys.stderr)
        return 2

    rows, skipped, failures = [], [], 0
    for preset, out, encoding in shapes:
        hexpath, jsonpath = table_paths(preset, out, encoding)
        if not os.path.exists(jsonpath):
            skipped.append((preset, out, encoding, 0, 0, 'no table generated'))
            continue
        with open(jsonpath) as f:
            meta = json.load(f)
        print('shape %s %s %s' % (preset, out, encoding))
        for n in photons:
            k, why = k_shot_for(meta, n)
            if k is None:
                skipped.append((preset, out, encoding, n, 0, why))
                print('  %g photons: skipped -- %s' % (n, why))
                continue
            for sigma in SIGMAS:
                for reset in RESETS:
                    # sigma = 0 has no detuning draw, so one seed is the whole
                    # story there; sigma > 0 needs several (see SEEDS).  Both
                    # references are run: against the ideal unit, and against
                    # the same unit calibrated.
                    seeds = (a.seed,) if sigma == 0.0 else SEEDS
                    for cal in (False, True):
                        if sigma == 0.0 and cal:
                            continue        # identical to cal=False at s = 1
                        depths, finals = [], []
                        for sd in seeds:
                            m, bad = run_point(hexpath, k, sigma, reset,
                                               encoding == 'amplitude', a.layers,
                                               sd, a.dry_run, cal)
                            if a.dry_run:
                                continue
                            if bad:
                                # Excluded, and why.  This is the gate catching a
                                # real RTL-against-C disagreement, which A3 reports
                                # rather than averages into a curve.
                                failures += 1
                                skipped.append((preset, out, encoding, n, sigma,
                                                'seed %d%s failed the per-layer '
                                                'bitwise check (%d elements)'
                                                % (sd, ' cal' if cal else '', bad)))
                                continue
                            if m is None:
                                skipped.append((preset, out, encoding, n, sigma,
                                                'the bench printed no RESULT line'))
                                continue
                            d = m.group(5)
                            depths.append(a.layers + 1 if d == 'none' else int(d))
                            finals.append(float(m.group(6)))
                        if a.dry_run or not depths:
                            continue
                        med = median(depths)
                        rows.append(dict(preset=preset, out=out, encoding=encoding,
                                         photons=n, k_shot=k, sigma=sigma, cal=cal,
                                         reset='inf' if reset is None else reset,
                                         depth=med, dmin=min(depths), dmax=max(depths),
                                         nseed=len(depths),
                                         final=sum(finals) / len(finals)))
                        print('  %7g ph  sigma %-5.1f reset %-4s %-4s depth@5%% '
                              'median %-4s range %s-%s (%d seed%s)  rel_rms %.4f'
                              % (n, sigma, 'inf' if reset is None else reset,
                                 'cal' if cal else 'ideal', fmt_depth(med, a.layers),
                                 fmt_depth(min(depths), a.layers),
                                 fmt_depth(max(depths), a.layers), len(depths),
                                 '' if len(depths) == 1 else 's',
                                 sum(finals) / len(finals)))

    if a.dry_run:
        return 0

    # The curve A3 exists to produce: depth at 5% against photons, per reset
    # interval. Printed per shape, because a shape is a different device.
    print()
    print("A3's curve: the depth the chain reaches before 5% relative RMS")
    print('(a dash is "never, within %d layers" -- the chain held.  Median over'
          % a.layers)
    print(' %d seeds with the range in brackets where it differs: the detuning'
          % len(SEEDS))
    print(' draw is 8 columns wide and varies.  sigma > 0 rows are against a')
    print(' CALIBRATED reference, so they are the noise alone; against the ideal')
    print(' unit a detuned chain reads 25%+ from depth 1 and shows nothing.)')
    for preset, out, encoding in shapes:
        sel = [r for r in rows if r['preset'] == preset and r['out'] == out
               and r['encoding'] == encoding]
        if not sel:
            continue
        print()
        print('  %s %s %s' % (preset, out, encoding))
        for sigma in SIGMAS:
            print('    sigma %.0f nm' % sigma)
            print('      %-10s' % 'photons', end='')
            for reset in RESETS:
                print('%10s' % ('N=inf' if reset is None else 'N=%d' % reset), end='')
            print()
            for n in photons:
                print('      %-10g' % n, end='')
                for reset in RESETS:
                    key = 'inf' if reset is None else reset
                    hit = [r for r in sel if r['photons'] == n
                           and r['sigma'] == sigma and r['reset'] == key
                           and r['cal'] == (sigma > 0.0)]
                    if not hit:
                        print('%10s' % 'skip', end='')
                    else:
                        h = hit[0]
                        cell = fmt_depth(h['depth'], a.layers)
                        if h['nseed'] > 1 and h['dmin'] != h['dmax']:
                            cell += '(%s-%s)' % (fmt_depth(h['dmin'], a.layers),
                                                 fmt_depth(h['dmax'], a.layers))
                        print('%10s' % cell, end='')
                print()

    if skipped:
        print()
        print('Not run, and why -- A3 reports gaps rather than filling them:')
        for preset, out, encoding, n, sigma, why in skipped:
            where = '%s %s %s' % (preset, out, encoding)
            if n:
                where += ' at %g photons' % n
            print('  %-42s %s' % (where, why))

    print()
    print('[A3] %d point(s) measured, every layer bitwise against the C reference'
          % len(rows))
    if failures:
        print('[A3] %d run(s) were EXCLUDED for failing that check. They are listed'
              % failures)
        print('     above with their seeds. The curve above is the points that'
              ' passed;')
        print('     an excluded cell is a gap, and the mechanism is recorded in the'
              ' design')
        print('     note -- f(x)*r_j overflows the output stage once r_j reaches'
              " Q4.12's")
        print('     limit of 16, which A2 never drove and so never covered.')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
