# grxcp → GRX930: all five verified, shim wired in, five defects found in it

Checked at your `817eb33` ("Address grxcp team feedback: context pointers, shim, doc fixes"). Every item confirmed against the source, not against the summary.

<table>
  <tr><th>#</th><th>Item</th><th>Verified</th></tr>
  <tr><td>1</td><td>_ctx variants</td><td>npu_tile_init_ctx at npu_tile.h:159, npu_tile_gemm_ctx at :162; context-free API unchanged</td></tr>
  <tr><td>2</td><td>NPU_NUM_COLS 8 → 4</td><td>#define NPU_NUM_COLS 4 // SoC default; override for different instantiations</td></tr>
  <tr><td>3</td><td>Table heading</td><td>now | Parameter | SoC default | Core default | Notes |</td></tr>
  <tr><td>4</td><td>Stale Verilator comment</td><td>zero occurrences of &quot;needs DDR init fix&quot; in the tree</td></tr>
  <tr><td>5</td><td>C shim</td><td>sim/npu_dpi_shim.c (5607 B) + .h (3164 B); builds clean under gcc -Wall -Wextra; libnpu_dpi_shim.a = 5516 B, eight exported symbols</td></tr>
</table>

Thank you for item 1 in particular — the `_ctx` form is the right shape and it is the same seam our backend uses (`npu_c930_attach_model`).

## The shim is in

Vendored byte-for-byte at `third_party/grx930/` and driven as a **fifth register model** alongside the four we wrote (absent, dead bus, live, never-finishes). `ctest -R npu_c930_shim`. Driven through it, the full `npu_c930_gemm` sequence — wait idle, program DIM/BASE/PREC, `CTRL.START`, poll, `STATUS.DONE`, read C — completes, and every element of C matches a host `INT8 × INT8 → INT32` reference.

This is worth more to us than the four we wrote, and for a specific reason: we wrote both sides of those conversations, so they are evidence about our decision logic and no evidence at all about the register map. Yours carries your addresses. That is the first independent check the map has had on this side.

## Five defects, measured on import

All reproduced. Nothing below is read off the source; each has a run behind it. They are recorded in `third_party/grx930/README.md` next to the vendored copy.

**1. **`npu_dpi_run_gemm()`** never starts the GEMM.** It writes DIM_M/N/K, A/B/C_BASE and PREC, then calls `npu_dpi_run()` — but never writes `NPU_CSR_CTRL`. `npu_dpi_run()` returns immediately because `npu_busy` is still 0. Measured with a 4×4×8 case:

```plaintext
npu_dpi_run_gemm(...) -> 28      (a plausible cycle count)
STATUS                 = 0x00000000
C[0][0]                = 0       (host reference says 35)


```

The one entry point that looks like an API returns a number and computes nothing. This is the one that would have made a naive wire-up look green, so it is worth fixing first. We drive the CSRs directly and do not call it.

**2. **`STATUS.BUSY`** (bit 0) is never asserted.** The map documents bit0 = BUSY and our `npu_c930_wait_idle()` polls it. Against the shim, STATUS reads `0x00000000` immediately after `CTRL.START`, so a BUSY-waiting host cannot tell running from finished. `STATUS.DONE` is the only thing that separates them — which we do check, and which is the only reason this is safe for us to use. A host that waited on BUSY alone would read C before the DMA had written it.

**3. The performance counters above **`CYCLE_COUNT`** are written one word low.** The header's addresses and the implementation's indices disagree:

<table>
  <tr><th>register</th><th>header address</th><th>written at</th><th>reading the header address gives</th></tr>
  <tr><td>CYCLE_COUNT</td><td>0x24 (idx 9)</td><td>idx 9</td><td>correct</td></tr>
  <tr><td>OP_COUNT</td><td>0x2c (idx 11)</td><td>idx 10 → 0x28</td><td>STALL_COUNT</td></tr>
  <tr><td>STALL_COUNT</td><td>0x30 (idx 12)</td><td>idx 11 → 0x2c</td><td>DMA_CT</td></tr>
  <tr><td>DMA_CT</td><td>0x34 (idx 13)</td><td>idx 12 → 0x30</td><td>zero, always</td></tr>
</table>

Measured at M=4 N=4 K=8: `0x24`=34, `0x28`=**256** (that is `M*N*K*2`, the OP_COUNT, at an address the header does not define), `0x2c`=0, `0x30`=34, `0x34`=0. The header's claim — *"STATUS, CYCLE_COUNT, OP_COUNT and STALL_COUNT update correctly"* — holds for one of the four.

The gap at `0x28` in the header suggests `CYCLE_COUNT` is meant to be 64-bit (lo `0x24`, hi `0x28`) and the implementation lost the high word, which would make the fix `csr[10]/[11]/[12]` → `csr[11]/[12]/[13]`. Worth confirming against `c930_npu_csr.sv` rather than taking our reading of it.

We have deliberately **not** gated on this — a red gate on someone else's defect turns our suite amber for a bug we cannot fix. Our test prints the observed layout every run instead; the gate arrives with the fix.

**4. The GEMM path indexes **`ddr[]`** with no bounds check.** `npu_dpi_mem_write` and `npu_dpi_mem_read` both range-check; the DMA emulation inside `npu_dpi_csr_write`'s START branch does not. Watched under ASAN with C_BASE = `0xfff0` and a 4×4 INT32 result:

```plaintext
ERROR: AddressSanitizer: global-buffer-overflow  WRITE of size 1
    #0 npu_dpi_csr_write  npu_dpi_shim.c:68
0x... is located 0 bytes after global variable 'ddr' ... of size 65536


```

Our adapter refuses a launch whose A/B/C extents leave the 64 KB window, the way an address decoder would, and raises `STATUS.ERROR` instead of forwarding `CTRL.START`. But it would be better in the shim: a clamp or an `ERROR` bit costs three lines and makes the model safe to hand to anyone.

**5. **`PREC`** is stored and ignored, and the cycle model is not the SoC's.** All four precision modes give the same INT8 answer (measured: `C[0][0] = 8` for PREC 0..3 with all-ones inputs at K=8). Separately, the cycle formula tiles 8×8 with `MAX_N = 12` hardcoded, while the SoC default you corrected in *this same commit* is a 4×4 array. At M=8 N=8 K=16 the shim says 36 cycles where the same formula shape over a 4×4 array says 160 — 4.4× apart. So `CYCLE_COUNT` from this model should not be quoted as the SoC's, and item 2's fix has not reached the shim.

Two cosmetics while we were in there: the header's usage comment writes `NPU_REG_DIM_M` / `NPU_REG_CTRL` / `NPU_REG_STATUS` where the actual defines are `NPU_CSR_*` (copy-paste bait — that comment is the first thing anyone will try), and line 71 reads *"Useful for知道 how many"*.

Worth noting for defect 1: that same usage comment has the sequence right — line 19 is `npu_dpi_csr_write(NPU_REG_CTRL, 1); // trigger GEMM`. The header knows a START is needed; only `npu_dpi_run_gemm()` forgot it.

## One correction to item 5's framing

Your note lists item 5 as **"Phase 7 blocker: ✅ Built"**. It is not, and we would rather say so now than have the two teams carry different pictures.

The shim computes the GEMM with a C triple loop, and its own header says it is not cycle-accurate. It is a model of the **interface**, not of the RTL. It can show that our host drives your register map correctly — genuinely useful, and it found real bugs on both sides today. It cannot show that the c930 does anything. Per our project rules no green run through a model may be reported as the NPU working, so the phase 7 exit gate (the same host program running an INT8 GEMM on the GPU device and on the NPU device by changing only `grxSetDevice`) is unchanged and still needs hardware or an RTL-backed simulation.

What item 5 *did* unblock is real: we can now exercise the backend end-to-end without a c930, which is exactly what we asked for. It moved the blocker, and it moved it onto our side.

## The next blocker is ours

Wiring your shim in was the first thing that ever asked what an NPU device does *after* it is enumerated, and the answer is: nothing, because there is no NPU memory path. `grxMalloc` on an NPU device reaches `vx_buffer_create(nullptr, …)` — measured, returns `VX_ERR_INVALID_VALUE` — so an allocation comes back "invalid value", blaming the caller's size for a device that has no allocator. Our own `test_grxblas_npu.cpp` could never have passed, hardware or not: it fails at its first allocation, before touching a register.

Three things on our list before an end-to-end `grxblasGemmEx` run is possible: an NPU allocator over the 64 KB DDR window; a seam so a model can be attached to the *enumerated* device (today the runtime and `grxblas.cpp` each hold their own `npu_c930_device_t`); and deriving the device's `backend` field instead of hardcoding `GRX_BACKEND_SILICON`, which would otherwise report your software GEMM model as silicon the moment the seam exists.

## What would help most next

1. **The four fixes above**, in roughly that order — 1 and 4 matter most.
2. **Confirmation of the **`0x28`** question**: is `CYCLE_COUNT` 64-bit in `c930_npu_csr.sv`? That decides whether the counter fix is a re-index or a header correction.
3. **Whether **`STATUS.BUSY`** is asserted by the real CSR block.** If the RTL does drive it, the shim should too, so a host tested against the shim behaves the same on silicon. If it does not, the register map documentation should say so, and every host should be told DONE is the only completion evidence.
4. Longer term, still the same ask: **hardware, or a simulation backed by the RTL.** The shim is a good stand-in for the interface and we will keep using it. It cannot close the exit gate.
