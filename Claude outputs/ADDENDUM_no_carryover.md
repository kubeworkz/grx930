# grxcp → grxgpu: addendum — no work is carried over, in either build

Nothing operational changes. The fix is right, `3d8785f11` is verified here
(byte-identical `sim/rtlsim/processor.cpp`, md5 `e3fd5b67…`; 8/8 on both probes,
`test_grxblas` PASSED at 4 cores). This corrects one more mechanism claim that
was in the report you built on, so it does not survive in the record.

## What we said, twice

Our original mechanism report said of the **unfixed** build:

> The work is not lost — it is still pending in the model, and the next `run()`'s
> ticks carry it out. That is the whole of the alternation.

We already corrected the same claim as applied to your first fix. We had not
tested it against the unfixed build, and it is wrong there too.

## Measured

`parity_probe2.cpp`, buffer per launch, checked after each sync and re-read at
the end. Unfixed `rtlsim` at 4 cores:

```
launch 0,2,4,6: *** silent ***
launch 1,3,5,7: wrote

4/8 written by the time the host read them
4/8 written by the end of the run
4 launches did not run at all.
```

**Zero buffers filled late, on either build.** A failing launch's work is not
deferred to the next call — it is never done at all.

What produced the "wrote" on the odd launches under the one-buffer probe was
the **shared buffer still holding the last successful launch's output**. A stale
read, not a carried-over frame.

## Why this matters for the record and not for the fix

The two stories predict the same pass/fail pattern on a one-buffer probe and
different things about *safety*:

* Carried-over frames imply a **silent wrong answer** — correct-looking output
  belonging to the previous launch, dangerous with differing arguments.
* Launches that never run imply **stale reads** — an output that is simply old,
  and a shared buffer that has never been written reads as empty.

Neither is acceptable and both are fixed by the same patch, so nothing you have
shipped changes. But "silent wrong answer" is the more alarming of the two and
we asserted it without testing it, so it should not stand in your commit
history or ours.

## The pattern, since it is the third instance today

Every one of these came from an instrument that could not distinguish the
hypothesis from its neighbour:

1. `grx_cycles.h` refused cross-core spans because MCYCLE is per-core
   *storage* — never tested whether it was per-core *time*. It is not.
2. Our first alignment probe concluded "small skew ⇒ aligned", which is
   backwards: independent counters are what produce a small skew.
3. This: a shared output buffer cannot tell "ran late" from "did not run".

In all three the reasoning was plausible and the instrument was blind in
exactly the direction the reasoning went. The probes are in
`tests/repro/rtlsim_run_busy/` and `tests/repro/cross_core_clock/` if any are
useful to you.
