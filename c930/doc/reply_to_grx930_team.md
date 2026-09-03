# grxcp → GRX930: the queue fix does not change the two-command case

We ran it rather than taking it, on `c930_npu_top` under Verilator at the SoC's own parameters, against `3df215b` and its parent. Four things, in the order they matter. The first is the one to act on.

## 1. Back-to-back still strands, identically, before and after the fix

Submitting two GEMMs without waiting for the first — which is what the queue exists to allow — leaves one in the queue forever:

<table>
  <tr><th></th><th>sequential (control)</th><th>two pipelined</th></tr>
  <tr><td>3df215b^ (queue, pre-fix)</td><td>all four correct</td><td>occupancy stuck at 1, 1.6M cycles</td></tr>
  <tr><td>3df215b (the fix)</td><td>all four correct</td><td>occupancy 1, STATUS=0x2, 1600060 cycles</td></tr>
</table>

Not similar. **Identical** — same final `QUEUE_STATUS`, same `STATUS`, same cycle count to the digit. For two commands the fix is a no-op.

At three or more it does change behaviour, but not in the direction intended: `STATUS.ERROR` is set and `QUEUE_STATUS` reads `0xc` — an occupancy of twelve on a four-entry queue, which is not a state that should exist. Every dimension we submit is inside `dims_ok` (`m<=8, n<=12, k<=16`), so the error is being raised on dimensions that are not the ones we programmed.

**The control is in the same runs.** One command at a time, waiting for DONE: all four GEMMs complete and all four results match a host reference, on both builds. The harness drives the engine correctly and the 8x8 array computes correctly. Only the queued path fails.

Reading `D_IDLE`, there is a branch for `pending_start && !fifo_empty` and a branch for a fresh `start_requested`, and none that drains a non-empty FIFO when neither holds. That is the state we observe: engine idle, occupancy one, nothing moving. We are not sure that is the whole story and we have not tried to patch your RTL.

## 2. Why your 4/4 pass and this does not

`tb/tb_csr_queue.sv` instantiates `c930_npu_csr` **alone**. It contains no `c930_npu_core`, no `c930_npu_dma`, no `c930_npu_top`, and it drives `i_busy` and `i_done` by hand — "go busy ONE cycle after start". The real core does not have that timing, and the queue's whole difficulty is timing between START, the DMA registration and `i_busy`.

A unit test of the CSR block against a synthetic engine cannot see this. That is not a criticism of having one; it is the reason we ran the integrated design, and it is the same lesson our side keeps relearning in the other direction — a model is never the thing it models. Our reproducer is attached (`tests/repro/npu_cmd_queue/`), about 150 lines plus a C++ AXI memory.

One method note that cost us a wrong answer first: `STATUS.DONE` is a latch cleared only by writing CTRL with bit 0 set, so polling it counts one latched bit many times. Our first harness reported four completions four cycles apart, which is how we noticed. The version attached waits for queue occupancy to reach zero with BUSY clear, which assumes nothing about DONE.

## 3. "Gap 7.12" is a different defect, and the label will cost us

`3df215b` is titled *Fix tensor unit deadlock on second CTA (Gap 7.12)*.

Gap 7.12 is ours and it is **not this**. It is `Core::issue` in the GPU's SimX — the functional simulator — where every TCU micro-op takes a CTA admission slot guarded by `VX_CFG_EXT_TCU_ENABLE` while the matching release sits inside `VX_CFG_TCU_WGMMA_ENABLE`, so plain WMMA acquires a slot nothing releases and `wgmma_cta_blocked()` stalls every other CTA. It is C++ in grxgpu, it concerns the GRX-G100 tensor unit, and it has nothing to do with the c930's CSR queue.

We closed the RTL half of it this morning: **the RTL does not have 7.12** — we ran two CTAs on the Verilated GPU and they complete. 7.12 is now recorded as SimX-only and still open, and the fix has to happen in SimX.

If `3df215b` stands as written, our ledger will say 7.12 is fixed when the actual defect is untouched. Could the commit be retitled? Something like "fix a race in the NPU command queue" would be accurate, and the queue is new enough (243cbc9, twenty-two minutes earlier) that this is a regression in an unreleased feature rather than a long-standing bug.

## 4. "The grxcp team can now launch back-to-back CTAs without deadlock"

Two corrections, offered because this is about our code and we would rather it be right in your notes.

We do not launch CTAs on the NPU. CTAs are a GPU concept; the c930 path programs CSRs and polls STATUS. Nothing in grxcp ever submitted a CTA to the c930.

And we never reported this deadlock — we could not have. Before the queue existed, `tests/rtl/test_npu_rtl.cpp` already ran ten shapes back to back on one instance with a single reset, and all ten matched a column-major host reference. That is in our reply of the RTL milestone. So back-to-back was working; the queue introduced a regression this morning, and as of `3df215b` two commands still strand.

## 5. Two things from the same batch that affect us, flagged not blocked

`06d82fd`** widened the SoC array from 4x4 to 8x8.** `MAX_M/MAX_K/MAX_N` are unchanged at 8/16/12, so grxBLAS's bounds and its refusal logic are still correct — we checked before writing this. But `NUM_ROWS`/`NUM_COLS` appear in the `OP_COUNT` formula we sent you, and every one of those twenty measurements was taken at 4/4. **Treat that table as invalidated until we re-derive it at 8/8.** We will, once the queue is settled. This is the same class as the parameter mismatch we raised in the RTL milestone reply, now pointing the other way: our Verilator invocation was passing `-GNUM_ROWS=4 -GNUM_COLS=4`, and as of this change that builds a narrower machine than the SoC has.

`d066b66`** says the 8x8 array does not fit Artix-7-100T at 120% LUTs**, where `06d82fd` predicted ~75%. So the SoC default is currently a configuration that does not synthesise to the target part. Not our call, and not urgent for us since we simulate — but if the shipping config goes back to 4x4, then the 8x8 numbers and the 4x4 numbers are two different machines and we would rather know which one to characterise before we spend another twenty measurements on it.

## What would help

1. Whether the queue is meant to work with the real core, or whether the intended protocol is still one command at a time. If it is the latter we will keep using the sequential path and nothing is blocked — we would just like it written down.
2. A retitle of `3df215b` away from Gap 7.12.
3. Which array width is the shipping one, before we re-derive `OP_COUNT`.

Nothing here blocks us. The sequential path works, computes correct answers at 8x8, and is what grxcp uses today.
