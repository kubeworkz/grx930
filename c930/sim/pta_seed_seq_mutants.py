#!/usr/bin/env python3
"""Non-vacuity check for pta_mnist's selftest check 3b, the seed sequence.

Check 3b holds every issued tile command's PTA_SEED, in order, to the derivation
grxcp's baseline pins (docs/designs/pta_fotonix_baseline.md section 7), at the
index this harness numbers it with.  The harness's numbering is what it pins --
the C1 model's, calibration included in one counter -- and not the tile's, whose
calibration seeds come from the engine (PTA_CAL_SEED ^ (j * 0x9E3779B1)).
A check that only ever agrees with the code it is checking proves nothing, so
this script builds the harness four times over, each time with one mutation
that stands for a way the sequence could drift while the accuracy stays green,
and requires every one to come back red:

  derivation                    one bit of splitmix64's output is dropped
  calibration ignores counter   the probe stops taking the run's indices
  calibration base off by one   the phase's seed base moves by one
  numbering restarts per batch  each batch counts from zero again

The unmutated build is the control and must stay green; if it does not, the
harness or the compiler is at fault, not the mutations.

  python3 sim/pta_seed_seq_mutants.py        # CC overrides gcc, as elsewhere
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(os.path.dirname(HERE), "build", "pta_seed_seq_mutants")
CC = os.environ.get("CC", "gcc")
CFLAGS = [CC, "-O2", "-std=c99", "-Wall", "-Wextra", "-pedantic", "-I" + HERE]
SOURCES = ("pta_mnist.c", "pta_tile_model.c")


def mut_derivation(text):
    """The harness's own packing changes: one bit of the derivation."""
    return text.replace("splitmix64(&s) >> 32", "splitmix64(&s) >> 31", 1)


def mut_cal_ignores_counter(text):
    """The probe stops consuming the run's index, the GEMM-count reading."""
    at = text.index("calibrate_bank(pta_device *dev")
    head, tail = text[:at], text[at:]
    old = "c.seed = seed_take(seed, gemm);"
    assert tail.count(old) == 1, tail.count(old)
    new = "{ static uint32_t zz; (void)gemm; zz = 0; c.seed = seed_take(seed, &zz); }"
    return head + tail.replace(old, new, 1)


def mut_cal_base(text):
    """The calibration phase's base moves by one."""
    return text.replace("PTA_CAL_SEED_XOR 0xCA11Bu", "PTA_CAL_SEED_XOR 0xCA11Cu", 1)


def mut_numbering_restarts(text):
    """Each batch restarts the counting.  tile_batch() consumes indices first."""
    anchor = "    const int64_t amax = ((int64_t)1 << (hn->din - 1)) - 1;"
    assert text.count(anchor) == 1
    return text.replace(anchor, "    *gemm = 0;\n" + anchor, 1)


MUTATIONS = [
    ("derivation", mut_derivation),
    ("calibration ignores the counter", mut_cal_ignores_counter),
    ("calibration base off by one", mut_cal_base),
    ("numbering restarts per batch", mut_numbering_restarts),
]


def build_and_run(name, mutate, expect_red):
    """One build of the harness, one selftest, and what check 3b said."""
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    for f in SOURCES:
        shutil.copy(os.path.join(HERE, f), WORK)
    path = os.path.join(WORK, "pta_mnist.c")
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    mutated = mutate(text)
    assert mutated != text, "mutation %s did not apply" % name
    with open(path, "w", encoding="utf-8") as f:
        f.write(mutated)
    exe = os.path.join(WORK, "pta_mnist")
    if subprocess.run(CFLAGS + ["-o", exe, path] + [os.path.join(WORK, f) for f in SOURCES[1:]]
                      + ["-lm"]).returncode != 0:
        print("%-32s BUILD FAILED" % name)
        return 1
    p = subprocess.run([exe, "selftest"], capture_output=True, text=True)
    print("%-32s exit %d  %s" % (name, p.returncode,
                                 "RED, as it must be" if p.returncode else "green"))
    for line in p.stdout.splitlines():
        if "issued" in line or "FAIL" in line or "passed" in line:
            print("    " + line)
    if bool(p.returncode) != expect_red:
        print("    ^^^ this mutation is not caught, or the control is not green")
        return 1
    return 0


def main():
    bad = build_and_run("unmutated (control)", lambda t: t + "\n", False)
    for name, mutate in MUTATIONS:
        bad += build_and_run(name, mutate, True)
    print("seed sequence check 3b is %s" % ("vacuous" if bad else "not vacuous"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
