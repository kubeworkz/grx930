# The M unit's result hold

**Date:** September 24, 2026
**Status:** fixed; `make mul_store` is the regression
**Found by:** C4(a)'s firmware, which could not get past `run_gemm`'s prologue

---

## Summary

A multiply or divide that finishes while the pipeline is stalled loses its
result and starts over. On its own that is only slow. With a store in the MEM
stage it never terminates: the two hold each other, and the CPU spins at a
constant PC for as long as you care to run it. `mulw` two instructions ahead of
a `sw` is enough — nine instructions in `sw/mul_store_test.S` do it.

This blocked C4(a): `sw/pta_test.c` boots, drives the PTA register block, and
then stops for ever on `sw a5,12(sp)` in `run_gemm`'s prologue, two
instructions after a `mulw a0,a0,a1` that computes `m * n`.

## 1. What the M unit does with its result

`riscv_core_booth` and `riscv_core_non_restoring` are iterative: 64 cycles for a
multiply. Both present their result for exactly **one** cycle — the cycle their
`done` pulses — and drive zero otherwise:

```systemverilog
      o_booth_product = 0;                      // every cycle but one
      ...
          if (cnt_next == 0)
            begin
              state_next = IDLE;
              o_booth_done = 1'b1;
              o_booth_product = {accumulator_next, multiplier_next};
            end
```

`riscv_core_mul_div` passed that straight out through two muxes, so
`o_mul_div_result` was live for that one cycle too, and the core has to latch it
into EX/MEM then or not at all.

`riscv_core_mul_div_ctrl` returns to `IDLE` on the same pulse and drops `busy`.
`i_mul_div_en` is `id_ex_pipe_im_sel` — "an M instruction is in EX" — which is
still asserted if the instruction has not left, so the FSM immediately starts
the operation again. Nothing tells it the result was never taken.

So a stall in the `done` cycle costs 64 more cycles and, silently, a
recomputation. That is survivable on its own: the operands are registered, so
the answer is the same.

## 2. Why it stops for ever with a store in MEM

The hazard unit stalls MEM while the M unit is busy:

```systemverilog
    o_hazard_unit_stall_mem = mstall_detection || icache_stall_detection ||
                              dcache_stall_detection || csr_mem_hold;
```

A store held in MEM keeps its request asserted, and the D-cache has no retire
guard on the cached path — `MEM_WRITE` is a write-through, so the store
completes, the controller returns to `IDLE`, sees the same request, and issues
it again. Every nine cycles, for ever:

```
cyc 7999992  dc0=3  aw=1/1          the write address accepted
cyc 7999996  dc0=3  w=1/1           the data accepted
cyc 7999997  dcs=0  b=1/1           the response, and one unstalled cycle
cyc 7999998  dc0=0  dcs=1           IDLE, and immediately stalled again
cyc 7999999  dc0=3                  the same store, again
```

That leaves `dcache_stall` high in eight of every nine cycles, and `mstall` high
whenever the M unit is busy. The M unit's one-cycle window has to land on the
one free cycle to make progress, and it does not: each restart re-phases the
attempt against the store's loop, and the store's loop is driven by the stall
the M unit is causing. The machine is live — the write channel is busy, the
D-cache is cycling — and no instruction retires.

The MMIO path was already guarded (`MMIO_WR_RETIRE` waits for the store to
leave MEM before accepting another), which is why the firmware's register writes
to `0x4000_0100` all worked and only a plain cached store to the stack spun.

## 3. What it took to see it

The symptom is a hang at a constant PC with the NPU idle, which reads like an
NPU or a register-block problem and is neither. Two things separated it:

- **`sw/driver_prog.hex` runs to completion on the same harness.** So it is not
  the harness, the boot path, the linker script or the driver library.
- **The same nine instructions with `addw` in place of `mulw` finish in 184
  cycles.** With `mulw`, eight million cycles and no store retired. One
  instruction is the whole difference.

`driver_test.c` has exactly one multiply and survives it: its nearest store is
six instructions and a taken branch away, so no store is in MEM when the M unit
is busy. `pta_test.c` has eight, and `-Os` put one two instructions ahead of a
stack store.

## 4. The fix

In `riscv_core_mul_div`, latch the result if it arrives into a stalled pipeline,
report `done` and drop `busy` while it is latched, and gate the control FSM's
enable so it cannot restart:

```systemverilog
  else if (res_held)
    begin
      if (!i_mul_div_stall_ex)          // the pipeline has taken it
        res_held <= 1'b0;
    end
  else if (ctrl_done && i_mul_div_stall_ex)
    begin
      res_held <= 1'b1;
      res_reg  <= ctrl_result;
      ...
```

With `busy` low and `done` high, `mstall_detection` is low, so `stall_mem` is
driven by the D-cache alone; the store retires on its next completion, the
pipeline advances, and the held result is latched into EX/MEM.

Two things about the clear condition are load-bearing:

- It is **EX advancing**, not `i_mul_div_en` falling. Back-to-back M
  instructions hold the enable asserted across the boundary, and a hold keyed on
  the enable would give the second one the first one's result. `pta_test.c` has
  three multiplies in a row, so this is not hypothetical.
- The hold is only taken when the pipeline **was** stalled in the `done` cycle.
  With EX free, the result is latched into EX/MEM that cycle and there is
  nothing to hold; taking the hold anyway would delay every multiply by a cycle.

`overflow` and `div_by_zero` are held with the result, because they are valid in
the same one cycle.

The D-cache's cached-store re-issue is left alone. It is idempotent — the same
address, the same data — so with the deadlock gone it costs bus cycles while an
M instruction is in EX and nothing else. A retire guard there, matching
`MMIO_WR_RETIRE`, would be the tidier machine and is a second change to the
memory path with no correctness case behind it.

## 5. What it is checked by

`make mul_store` runs `sw/mul_store_test.S` on the Verilator four-core SoC and
checks the arithmetic as well as the liveness, because a lost-and-recomputed
result is invisible in a hang test: the first product, two back-to-back
multiplies, a divide, and the data of the store that used to spin.
`make mul_store NO_MUL=1` is the control, the same program with `addw`.

## 6. Open

- The one-cycle result window is still the interface between the M unit and the
  core; the hold covers it, but a datapath that registered its own result would
  not need covering.
- The hold puts a 2:1 mux in the M unit's result path, which is a candidate for
  the critical path once C4(b) measures the SoC in Vivado. Nothing here has been
  timed; if it shows up, the answer is to register the datapath's own result
  rather than to mux at the boundary.
- Nothing checks the *cost* of the recomputation path — a multiply that finishes
  into a stall now keeps its answer, but a multiply that is restarted for some
  other reason would still take 64 cycles more, and no gate would notice.
