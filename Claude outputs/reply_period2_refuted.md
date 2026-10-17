# grxcp → grxgpu: our reports crossed, and the period-2 story is inverted

Yours was written against our earlier report — the one that had eliminated
candidates but not named a mechanism. We have since found and fixed it, and
that report is with you separately. This is the part of yours that the
measurements now contradict, plus one question where you may have data we do
not.

Taken in the spirit yours was written: we have been wrong twice in this same
investigation, once by retracting a correct elimination because you asserted
otherwise.

## 1. The `future_.valid()` alternation does not happen

Your model:

> Odd launches: `future_` is not valid → `dcr_write` does NOT wait → arguments
> are correct. Even launches: `future_` IS valid → `dcr_write` waits → the
> Verilated model reads arguments while they are being staged → corruption.

We instrumented that exact flag on your HEAD at `NUM_CORES=4`. Every one of the
twenty DCR writes per launch, plus the outcome:

```
[hook] L0 dcr_write addr=0x010 val=0x80000000 future_valid=0   launch 0: *** silent ***
[hook] L1 dcr_write addr=0x010 val=0x80000000 future_valid=1   launch 1: wrote
[hook] L2 dcr_write addr=0x010 val=0x80000000 future_valid=1   launch 2: *** silent ***
[hook] L3 dcr_write addr=0x010 val=0x80000000 future_valid=1   launch 3: wrote
```

Two things, either of which is fatal to the model:

**It does not alternate.** `future_valid` is 0 exactly once — the first launch —
and 1 for every launch after. There is no oscillating state to drive a period
of two.

**The correlation is backwards.** The launch with `future_valid=0`, which your
model says must be correct, is the one that **fails**. The launches with
`future_valid=1`, which must be corrupt, are the ones that **pass**.

And the DCR payload is byte-identical on failing and passing launches — all
twenty registers, `0x010` through `0x023`, same values every time. Nothing is
corrupted at the DCR interface on the launches that fail.

## 2. Your fix, tested

We compiled it and the settle loop from our other report into one binary, each
behind an environment variable, so all four cases are the same build at
`NUM_CORES=4` on your HEAD:

| | `sgemm_shape` × 8 |
|---|---|
| neither — your HEAD as shipped | 4/8 |
| **`vortex_start` serialization only (your proposal)** | **4/8** |
| `Processor::run()` settle loop only | **8/8** |
| both | 8/8 |

**Your change is still worth taking, and we were wrong about why.** Our first
reaction was that it must be a no-op, because `future_ = std::async(...)`
already blocks in the old shared state's destructor. Measured, it does not:
`std::async` starts the new thread *before* the assignment destroys the old
future. A four-iteration test with a 200 ms body observes two overlapping runs.
So there is a genuine overlap window and you should close it — it is simply not
what drops the arguments.

## 3. "Why simx is immune" rests on something that is not true of simx

> simx processes everything in a single-threaded loop. `processor_.dcr_write()`
> is a direct function call that completes instantly. There is no memory bus,
> no clock edges, no pipeline.

`sw/runtime/simx/vortex.cpp:155`:

```cpp
future_ = std::async(std::launch::async, [&] { processor_.run(); });
```

simx runs on the **same** `std::async` future, with the same `future_.valid()`
guards on `dcr_read` (line 149) and the same absence of one on `dram_write`.
The runtime structure is not the difference between the two backends. You are
right that the models differ — but the immunity cannot be explained by a
threading property simx does not have, and an explanation that would also
predict rtlsim's behaviour is worth more than one that does not.

## 4. The question we would actually like answered

> We have reproduced the alternating pass/fail pattern at `NUM_CORES=2` and
> `NUM_CORES=4` on our G100 simx build.

We cannot. simx at `NUM_CORES=4`, same probe, same kernel, same argument blob,
eight launches:

```
device GRX-G100 (simx) backend=0 SMs=4 warps/SM=16
launch  0..7: wrote        8/8 launches wrote
```

Clean, repeatedly, and this has been one of our load-bearing eliminations since
the beginning — it is what exonerated grxcp and everything the two backends
share. Your own document also says simx is immune, in the section above, so the
two halves disagree with each other as well as with us.

**So: what did that run actually do?** If you have a genuine simx reproduction
it is important and it overturns an elimination we have been building on. If
it was an rtlsim run, or a different test, the reproduction line should come
out of the summary, because it is the row a reader will act on.

## 5. The mechanism, since it explains the rest

`Processor::run()` in `sim/rtlsim/processor.cpp` — untouched by `b09ca185e`,
and byte-identical between our trees throughout. `busy` is already high on
entry, out of reset and at the end of every frame, and dips low for exactly one
cycle after the start pulse:

```
t=0 busy=1 | t=1 busy=0 | t=2 busy=1 | t=2318 busy=0
```

So the "wait for device to go busy" loop never runs (`wait_i = 0` measured on
every launch) and the drain loop takes its first tick onto the dip and exits
(`busy_ticks = 1`). The frame executes **one cycle of about 2300** and returns.
The work is not lost — the next `run()`'s ticks complete it — so the host reads
the previous launch's buffer, which is what makes it look like alternating
argument corruption. Thirteen lines fix it and `test_grxblas` then passes at
four cores.

This also accounts for the things the DCR story has to explain separately: why
launch 0 fails with nothing in flight, why the payload is identical on failing
and passing launches, and why the period is 2 at both 2 and 4 cores.

## 6. Our performance numbers are no longer single-core

> We note that all your current performance numbers were measured on a single
> core.

True when you wrote it. The fix made multi-core measurable, and the first thing
it showed was that our own instrument was refusing to measure it — `MCYCLE` is
per core and `grx_cycles.h` had refused cross-core spans on an assumption
nobody had tested. Measured on both backends, the per-core counters share an
origin, so the refusal was unnecessary. Transformer block at S=16, summed
stage spans:

| SMs | cycles | ratio |
|---|---|---|
| 1 | 328987 | 1.00× |
| 2 | 208987 | 1.57× |
| 4 | 166577 | 1.97× |

With the launch preamble included — which every span excludes, and which we had
also never read — end to end it is **1.27×** at four SMs, because the block is
61% launch overhead at that width and the per-launch preamble grows with core
count. We will send that separately; it matters more to our roadmap than to
yours, but the preamble is device-side and you may want to know it is there.

## 7. On `RUNTIME_ASSERT`

Agreed, and thank you for keeping it. `VX_lsu_slice.sv:233` is what turned a
silent wrong answer into a stop, and it is the reason we now gate on rtlsim
rather than developing against simx alone. If you do add a comment, the useful
thing to record is not this bug but the class: the assertion fired on a
dereference of a pointer field the kernel had never been given, two layers
downstream of the actual defect, and it was still the fastest route to it.
