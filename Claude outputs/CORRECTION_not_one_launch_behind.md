# grxcp → grxgpu: correction — the "one launch behind" explanation was wrong

The conclusion in our last note stands and is measured. The **mechanism** we
gave you for it does not, and you have now put it in your summary, so this
needs correcting before it propagates.

## What we told you

> Draining before the pulse consumes the previous frame's work. The frame's work
> happens during the next `run()` call — so with identical arguments (regression
> test), results look correct but are actually one launch behind.

We built a probe specifically to detect that, because our first one could not:
`parity_probe2.cpp` gives **every launch its own output buffer**, checks buffer
`i` immediately after synchronising on launch `i`, and then re-reads every
buffer at the end. Work landing one call late shows up as a buffer that was
empty when the host read it and is written by the end.

On your `506e21321` as committed:

```
launch  0: *** silent ***
launch  1..7: wrote

7/8 written by the time the host read them
7/8 written by the end of the run
1 launch did not run at all.
```

**Zero buffers filled late.** Every launch after the first writes its own
buffer, in its own call, before the host reads it. There is no shift, and an
identical-argument regression test would not be silently passing on stale data.
We were wrong about that.

## What is actually true

Your fix repairs launches 1..N and **does not repair launch 0**.

At reset `busy` is high but falls almost immediately — measured, the pre-pulse
drain runs for **1 tick** on launch 0 against roughly 1650 on every later
launch. So on the first launch the drain consumes nothing, the pulse lands while
the model is in the reset state, `busy` dips one cycle later, and the drain loop
exits after a single tick. Launch 0 executes essentially nothing. On later
launches the long pre-drain leaves the model in a different state and the frame
does run in its own call.

So the correct one-line statement is: **the drain in the wrong position leaves
exactly the first launch broken.**

## Why that still aborts `test_grxblas`

Not because of shifted results — because **the first launch is the one that
matters**. `grxblas` opens by launching `sgemm_shape` to read the kernel's tile
geometry. That is launch 0. It reports nothing, grxBLAS falls back to the
reference kernel, and the run then dies on the misaligned dereference at
`VX_lsu_slice.sv:233`.

Any program whose first launch establishes something the rest depends on — a
shape probe, a capability query, an initialisation kernel — fails on your commit.
A program that happens to start with throwaway work does not. That is a
narrower and more predictable hazard than the one we described, and it is worse
in one specific way: it is invisible to a test that only checks its steady state.

## What does not change

| | `sgemm_shape` ×8 (either probe) | `test_grxblas`, 4 cores |
|---|---|---|
| `506e21321` verbatim | 7/8, launch 0 fails | **aborts** |
| drain moved after the pulse | 8/8 | **PASSED (0 failures)** |

The patch is unchanged and correct. Only our explanation of the failure mode
was wrong.

## The part worth keeping

We told you last time that catching this was luck rather than method, because
our probe reused one buffer. We built the better probe to remove that luck —
**and the better probe refuted the story we had already sent you.** The buffer-
per-launch version is in `tests/repro/rtlsim_run_busy/parity_probe2.cpp` if you
want it; it distinguishes a launch that never ran, work that lands in a later
call, and work that lands in the wrong slot, which the original could not tell
apart.

An explanation that fits the symptom is not the same as one that has been
tested, and we shipped the first as though it were the second.
