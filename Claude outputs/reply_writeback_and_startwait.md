# grxcp → grxgpu: the writeback test is already run, and it points the other way

Three things, in the order they matter. The first needs no build at all.

## 1. `DCACHE_WRITEBACK=0` is what every failing run we have was built with

The macro is not free to set. From the generated header:

```
`define VX_CFG_DCACHE_WRITEBACK  ((L2_ENABLED == 0) && (L3_ENABLED == 0))
                              && ((NUM_CORES == 1)  && (NUM_CLUSTERS == 1))
```

So at `NUM_CORES=2` it is **already 0**, and
`CONFIGS="-DVX_CFG_NUM_CORES=2 -DVX_CFG_DCACHE_WRITEBACK=0"` sets it to the
value it already has. The suggested experiment is every failing run in this
investigation.

**And the correlation runs the other way.** From the build logs of the three
configurations we have measured:

| build | `NUM_CORES` | `DCACHE_WRITEBACK` | `L2_ENABLED` | result |
|---|---|---|---|---|
| c1 | 1 | **1** | 0 | **clean, 8/8** |
| c2 | 2 | **0** | 0 | 4/8 |
| c4 | 4 | **0** | 0 | 4/8 |

The hypothesis — write-back L1 caches the argument before the write completes
and serves it stale — predicts corruption **with** writeback and clean
**without**. Measured: clean with, corrupt without. The one configuration that
has write-back L1s is the only one that works.

That is enough to retire the L1 as the mechanism without running anything, and
it is why the Verilator problem below, while real, is not blocking this
question.

## 2. Your `vortex_start` serialization: tested, and it changes nothing here

We compiled both fixes into one binary, each behind an environment variable, so
the four cases are the same build:

| | `sgemm_shape` × 8 |
|---|---|
| A. neither — your HEAD as shipped | 4/8 |
| B. **`vortex_start` serialization only** | **4/8** |
| C. `Processor::run()` settle loop only | **8/8** |
| D. both | 8/8 |

B is your proposal. It does not change the result, and D shows it adds nothing
on top of the other.

**We were wrong about why, and the correction matters to you.** Our first
reaction was that your fix would be a no-op because `future_ = std::async(...)`
already blocks — the old shared state's destructor waits. Measured, it does
not: `std::async` starts the new thread *before* the assignment destroys the
old future, so there is a genuine overlap window. A four-iteration test with a
200 ms body observes two overlapping runs. **Your change closes a real race and
is worth taking on its own terms.** It is just not this bug.

## 3. What this bug is

Sent separately, and it is upstream of everything above: `Processor::run()` in
`sim/rtlsim/processor.cpp` ends the frame on the wrong edge. `busy` is already
high on entry — out of reset and at the end of every frame — and dips low for
exactly one cycle after the start pulse:

```
t=0 busy=1 | t=1 busy=0 | t=2 busy=1 | t=2318 busy=0
```

So the "wait for device to go busy" loop never runs (measured `wait_i = 0`) and
the drain loop takes its first tick onto the dip and exits (`busy_ticks = 1`).
The frame executes **one cycle of ~2300** and `run()` returns. The work is not
lost — the next `run()`'s ticks carry it out — which is why it looks like every
other launch's arguments are corrupted. Thirteen lines fix it, and
`test_grxblas` then passes at 4 cores.

That also explains the writeback result in §1 without needing the cache at all.

## 4. Verilator: ours elaborates 2 and 4 cores

We are on **Verilator 5.020** (Debian 5.020-1) and it builds `NUM_CORES=2` and
`NUM_CORES=4` without the recursion problem, so 5.031 hitting it is a version
or configuration difference rather than an inherent limit. If you can try 5.020
that is the cheapest path back to running the test yourselves.

We tried to diagnose it from the RTL and **failed**, which is worth saying
rather than sending you a guess. The theory was that `VX_stream_arb`'s
`fanout_join_arb` recursion reaches a fixed point when `NUM_OUTPUTS >=
MAX_FANOUT`. Checking the parameter definition killed it:

```
NUM_REQS = (NUM_INPUTS > NUM_OUTPUTS) ? CDIV(NUM_INPUTS, NUM_OUTPUTS) : ...
NUM_SLICES = CDIV(NUM_REQS, MAX_FANOUT)
```

`NUM_REQS` is the input/output **ratio**, not the input count, and the join
recurses with a new ratio of `CDIV(NUM_REQS, MAX_FANOUT)` — it shrinks by 8×
per level and terminates at ratio ≤ 12. That is a handful of levels from any
plausible starting point, not 100.

So the descent is sound as written, and 100 levels means something other than
the intended one is happening — possibly a ping-pong between the
`NUM_INPUTS > NUM_OUTPUTS` branch and its else. Before concluding it is a tool
limitation, the cheap thing is to print `(NUM_INPUTS, NUM_OUTPUTS, NUM_REQS)`
at each level and see what the sequence actually does. If it is not descending,
the recursion is the bug and the depth cap is just where it surfaced.
