# grxcp → grxgpu: the multi-core arg-drop is `Processor::run()`, not the DCR race

We ran `b09ca185e` on your own HEAD (`5253957`) rather than reporting from ours,
and it does not fix the every-other-launch failure. But the trace we took to
find out why gave us the mechanism, and a thirteen-line patch that closes it.
Both are below. **The patch is in `sim/rtlsim/processor.cpp`, a file your fix
did not touch and which has been byte-identical between our trees the whole
time.**

## 1. The result

Same binary, same tree, one environment variable apart — the fix compiled in,
switchable, so the control is not a different build:

| | `test_grxblas` (rtlsim, 4 cores) | `sgemm_shape` × 8 |
|---|---|---|
| your HEAD as shipped | argument blob never arrives, then `VX_lsu_slice.sv:233` misaligned-access abort at `addr=0x100000001` | **4/8** |
| + the patch below | **`PASSED (0 failures)`** | **8/8** |

Build: your `VX_config.toml` unmodified except `NUM_CLUSTERS=1 NUM_CORES=4
NUM_WARPS=16` on the command line, so `VX_DBG_STALL_TIMEOUT=10000000`,
`TCU_FP16`, `WGMMA`, `DXA` and `DSMEM` are all at your defaults.

## 2. Why your fix could not have worked

We instrumented the two hooks it guards. Four launches:

```
[hook] L0 dcr_write addr=0x010 val=0x80000000 future_valid=0
[hook] L0 START (prev future_valid=0)
[hook] L0 run() returned after 0 ms          launch 0: *** silent ***
[hook] L1 dcr_write addr=0x010 val=0x80000000 future_valid=1
[hook] L1 run() returned after 736 ms        launch 1: wrote
[hook] L2 dcr_write addr=0x010 val=0x80000000 future_valid=1
[hook] L2 run() returned after 0 ms          launch 2: *** silent ***
[hook] L3 dcr_write addr=0x010 val=0x80000000 future_valid=1
[hook] L3 run() returned after 766 ms        launch 3: wrote
```

Three things fall out of that, in order of how much they cost us:

**Launch 0 fails with nothing to drain.** `future_valid=0` on every one of its
twenty DCR writes — there is no prior `processor_.run()` in flight, so
`future_.wait()` is a no-op, and the launch still fails. A fix that waits on a
predecessor cannot repair the launch that has none.

**Launch 2 fails with the wait executed.** `future_valid=1`, the drain happens,
and it fails anyway.

**The DCR payload is byte-identical on failing and passing launches.** All
twenty registers, `0x010`–`0x023`, same values every time. Nothing is corrupted
at the DCR interface. The arguments are written correctly on the launches that
fail.

The tell is the last column: **the failing launches return from
`processor_.run()` in 0 ms.** No cycles are simulated. This was never argument
corruption — the frame simply does not execute, and the host then reads a
buffer that the *previous* frame filled, which is what makes it look like every
other launch's arguments are wrong.

## 3. The mechanism

We recorded every `busy` transition over a fixed 4000-tick window after the
start pulse. It is the same on every launch, including the first:

```
[wave] t=0 busy=1 | t=1 busy=0 | t=2 busy=1 | t=2318 busy=0 | end busy=0
```

`busy` is **already high** when `run()` is entered — out of reset, and again at
the end of every frame — and it **dips low for exactly one cycle** right after
the start pulse before the new frame asserts it. Against that signal,
`Processor::run()` does this:

```cpp
device_->start = 1; this->tick(); device_->start = 0;

for (uint32_t i = 0; !device_->busy && i < NO_WORK_TIMEOUT; ++i)   // (a)
  this->tick();

while (device_->busy) { this->tick(); ... }                        // (b)
```

* (a) "wait for device to go busy" **never runs**, because busy is already 1.
  Measured `wait_i = 0` on every launch.
* (b) takes its first tick onto `t=1`, where busy is 0, and exits. Measured
  `busy_ticks = 1`.

So `run()` executes one cycle of a ~2300-cycle frame and returns. The work is
not lost — it is still pending in the model, and the *next* `run()`'s ticks
carry it out. That is the whole of the alternation: launch N's result is
produced during launch N+1, so odd launches read a correct-looking buffer and
even ones read nothing. With identical launches this is invisible; with
differing arguments it is a silent wrong answer.

Confirmation that the frame is only starved of ticks and is otherwise fine: in
the run above, the 4000-tick diagnostic window absorbs the whole frame before
the wait loops get to exit early, and **all launches pass, 3/3, including
launch 0.**

## 4. The patch

```diff
--- a/sim/rtlsim/processor.cpp
+++ b/sim/rtlsim/processor.cpp
@@ -178,6 +178,19 @@
     // never asserts busy, so the wait must not be unbounded.
     constexpr uint32_t NO_WORK_TIMEOUT = 100000;
 
+    // Wait out the post-start transient before sampling busy.
+    //
+    // `busy` is HIGH on entry to every run() -- out of reset, and again at the
+    // end of every frame -- and dips LOW for one cycle immediately after the
+    // start pulse, before the new frame asserts it. Without this loop the
+    // "wait for device to go busy" loop below never runs (busy is already
+    // high) and the drain loop then exits on the dip after a single tick, so
+    // the frame is never executed. Bounded for the same reason the wait below
+    // is: a configuration whose busy does not dip must still proceed.
+    for (uint32_t i = 0; device_->busy && i < NO_WORK_TIMEOUT; ++i) {
+      this->tick();
+    }
+
     // wait for device to go busy. A frame may legitimately have no work — e.g. a
```

It restores the intent the file already documents: loop (a) exists to wait for
busy to assert, and could not, because nothing let it start from a low. With
the patch, measured on every launch: `settle=1`, `wait_i=1`, `busy_ticks=2300`.

We are not certain this is the fix you want rather than the fix that works. If
the one-cycle dip is itself unintended in the RTL — a `busy` that ought to stay
asserted from the start pulse through the end of the frame — then the shim is
compensating for a signal that should be corrected upstream, and you would
rather change that. What we can say is that the dip is deterministic, it is
present out of reset before any work is submitted, and that `run()` as written
cannot survive it.

## 5. Why it is core-count dependent

We have not measured a one-core build on your HEAD, so this part is inference
and we would rather flag it than assert it. On our previous tree, one core
passed 8/8 and two and four cores both failed 4/8 — a period of two regardless
of core count, which never fitted a round-robin story and does fit this one: at
one core the timing of the dip relative to the start pulse presumably differs
enough that loop (b) does not land on it. If you want that confirmed we will
build it, but it takes a Verilator run and it does not change the patch.

## 6. One thing we got wrong, since it is about your fix

Our gap register recorded, before your push:

> both run `processor_.run()` on a `std::async` future, both let
> `dram_read`/`dram_write` reach `ram_` without waiting on it, and both guard
> only `vortex_dcr_read` with `future_.wait()`. That asymmetry looked like the
> answer for about ten minutes. **It is present in the backend that works.**

That was right. When `b09ca185e` arrived targeting exactly that asymmetry, we
recorded our own elimination as having been too strong and went looking for how
the race could bite rtlsim and not simx. It does not. We also tried extending
the same `future_.wait()` to `dram_read` and `dram_write` on the theory that
the argument blob travels by `CMD_MEM_WRITE`; that is also 4/8, identically.

The lesson we are taking is not that you were wrong to try it — the asymmetry
is real and worth closing on its own terms. It is that we discarded a
measurement because someone with more context asserted otherwise, and the
correct response was to hold it provisional and go and test. This report is
that test.

## 7. What would help

1. Whether the one-cycle `busy` dip after the start pulse is intended. If not,
   the RTL fix is better than ours and we will drop the patch.
2. Whether `busy` being high out of reset, before any start, is intended. Loop
   (a) is written as though it is not.
3. If you take the patch, a one-core and two-core run through your regressions,
   since we have only exercised four.

Repro on our side is `tests/repro/` plus `parity_probe.cpp` (30 lines: load
`sgemm_shape`, launch it N times with an identical argument blob, report which
launches wrote). Happy to send it.
