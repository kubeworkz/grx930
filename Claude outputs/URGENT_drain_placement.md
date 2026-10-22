# grxcp → grxgpu: check where the drain loop landed — before or after the start pulse

Glad it is fixed, and thank you for taking it. **One thing to check before this
ships**, because your comment reads as the placement we measured and rejected,
and the wrong one passes the obvious test.

## The two placements are not equivalent

Your applied fix:

```cpp
// drain any residual busy from the previous frame before starting a new one.
constexpr uint32_t DRAIN_TIMEOUT = 100000;
for (uint32_t i = 0; device_->busy && i < DRAIN_TIMEOUT; ++i) {
  this->tick();
}
```

"before starting a new one" is the position we tried **first** and it is not the
one we sent. In the patch, the loop goes **after the start pulse**:

```cpp
    // pulse start for one cycle
    device_->start = 1;
    this->tick();
    device_->start = 0;

    constexpr uint32_t NO_WORK_TIMEOUT = 100000;

    // >>> the loop goes HERE, after the pulse <<<
    for (uint32_t i = 0; device_->busy && i < NO_WORK_TIMEOUT; ++i) {
      this->tick();
    }

    // wait for device to go busy   (this one now actually runs)
    for (uint32_t i = 0; !device_->busy && i < NO_WORK_TIMEOUT; ++i) {
      this->tick();
    }
```

Measured, same build, the only difference being which side of the pulse the
loop sits on:

| placement | result | what the frame does |
|---|---|---|
| **before** the start pulse | **7/8** | `predrain≈1650, busy_ticks=1` — the frame does **not** run inside its own `run()` |
| **after** the start pulse | **8/8** | `settle=1, wait_i=1, busy_ticks≈2300` — the frame runs in its own call |

## Why the wrong one is worse than no fix

Draining *before* the pulse consumes the **previous** frame's outstanding work.
The current frame's start pulse is then issued, `busy_ticks` is still 1, and
`run()` returns having executed nothing — its work is carried out during the
*next* call's drain. That is why it scores 7/8 rather than 4/8: the results are
still one launch behind, and launch 0 has no predecessor so it still fails.

**With an identical argument blob every launch — which is exactly what a
regression test uses — one-launch-behind is indistinguishable from correct.**
With differing arguments it is a silent wrong answer. A fix that turns a loud
failure into a quiet one is a worse position than the bug.

The post-pulse placement is different in kind: it rides out the one-cycle dip so
that the existing "wait for device to go busy" loop can finally do the job it
was written for, and the frame executes inside the call that started it.

## How to tell which one you have, in one line

Print `busy_ticks` — the iteration count of the final `while (device_->busy)`
drain — once per `run()`:

* `busy_ticks ≈ 1` on every launch → the frame is not executing in its own
  call. Wrong placement, however good the pass rate looks.
* `busy_ticks ≈ 2300` (whatever a frame actually costs) → correct.

If it reads 1 and your tests pass, the tests are passing on the previous
launch's results.

## The rest

Your two other points match ours: the `vortex_start` serialization is worth
taking on its own terms — we measured that `future_ = std::async(...)` does not
serialize, so it closes a real window — and it does not change this result
(4/8 with it alone, 8/8 with the drain in the right place).

One item still open on our side, not blocking: your summary says you reproduced
the alternation on **simx** at 2 and 4 cores. We get 8/8 clean on simx at 4, and
your own analysis section says simx is immune. If that simx reproduction is
real it overturns an elimination we have been building on for weeks, so we would
rather know. If it was an rtlsim run, the line is worth correcting in the
summary — it is the row a reader acts on.
