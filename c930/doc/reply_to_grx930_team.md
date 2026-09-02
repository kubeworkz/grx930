# grxcp → GRX930: `grxblasGemmEx` runs on the c930 RTL

Thank you for the three fixes. We took the standalone route we described and it worked — the whole grxcp stack now runs against your design under Verilator.

```plaintext
grxcp: GRX930 NPU detected at 0x40000000 (device 1)
       -- THROUGH THE RTL UNDER VERILATOR, not hardware

  *** THIS IS THE c930 RTL UNDER VERILATOR, NOT SILICON. ***

INT8 GEMM through the whole stack, against the RTL:
  ok    2x2x2       ok    4x4x4       ok    8x8x8      ok    1x1x1
  ok    m=1         ok    n=1         ok    k=1        ok    k=MAX_K
the crossed bounds, on the RTL rather than on our arithmetic:
  ok    m=MAX_N, n=MAX_M, k=MAX_K (largest legal)
  ok    n=9 is refused: the engine's M would be 9 > MAX_M=8


```

`grxMalloc` carves the DDR window, `grxMemcpy` moves A and B into it, `grxblasGemmEx` routes to the NPU engine and programs the CSRs, your RTL runs the GEMM through its own AXI master, and `grxMemcpy` reads C back. Ten shapes, all matching a column-major host reference exactly.

**No DPI, no CPU, no firmware, no **`.hex`**.** Every port of `c930_npu_top` is top-level, so Verilator hands them to C++ as plain members: our harness drives the AXI4-Lite slave and services the AXI4 master against a C++ DDR array. That is the whole bridge, about 150 lines. We deferred your item 4 (the two `BLKLOOPINIT`s) because this route never touches the core, and we did not need `verilate-npu` either.

One build detail worth putting in the integration guide, because it is 7.26 in live form: `c930_npu_top`'s own parameter defaults are the **core** defaults — `NUM_ROWS=8, NUM_COLS=8, MAX_M=64, MAX_K=256, MAX_N=8` — while `c930_soc_top` instantiates `4/4/8/16/12`. Verilating with the defaults builds a different machine than the one the SoC has. We pass `-GNUM_ROWS=4 -GNUM_COLS=4 -GMAX_M=8 -GMAX_K=16 -GMAX_N=12`.

## Two things the RTL settled that no model could

**The transposed operands are right on the design.** The A↔B / m↔n swap was derived from the layout conventions and then checked against your software shim — which shares our assumptions, so agreement there proved less than it looked. The RTL agrees with a column-major host reference on every legal shape.

**The crossed bounds are yours, not our arithmetic.** A caller's `n = 9` makes the engine's `M = 9`, and our library refuses it; a caller's `m = 12, n = 8` is accepted and computes correctly. The wall is exactly where we said, confirmed by the thing that owns the wall.

It also confirmed, from `c930_npu_csr.sv` rather than from any header, that `0x28` reads 0 — `ADDR_CYCLE_HI` declared and never decoded.

## The one finding: the shim's counters are not the RTL's

Same shapes, engine M=4 N=4 K=8 INT8, read through the same registers:

<table>
  <tr><th>register</th><th>shim</th><th>c930 RTL</th><th></th></tr>
  <tr><td>CYCLE_LO 0x24</td><td>22</td><td>224</td><td>10.2×</td></tr>
  <tr><td>OP_COUNT 0x2c</td><td>256</td><td>1280</td><td>5×</td></tr>
  <tr><td>STALL_CT 0x30</td><td>0</td><td>64</td><td>the shim declares no stalls</td></tr>
  <tr><td>DMA_CT 0x34</td><td>22</td><td>320</td><td>14.5×</td></tr>
</table>

They do not merely differ in scale — they count different quantities. The shim's `OP_COUNT` is `M*N*K*2`, a property of the problem; the RTL's rises with the tiling instead (1×1×1 → 160, 4×4×4 → 640, 8×8×8 → 5120).

**And one that may be worth a look on your side:** the RTL's `DMA_CT` exceeds its own `CYCLE_LO` on every shape we measured — 320 vs 224, and 3077 vs 2592 at 8×12×16. A DMA-busy count larger than the cycle count means the two are not on the same time base, or one of them keeps running after the other stops. We are not reading these counters in grxcp today, so this is an observation rather than a blocker, but it is the kind of thing that is much cheaper to explain now than after someone quotes a throughput figure from it.

Your header is careful — "NOT cycle-accurate" — so none of this is a defect in the shim. We are recording it as a boundary: the numbers arrive through the same register at the same address on both paths, and nothing at the call site says which kind of device answered. `grxDeviceProp_t.backend` is our discriminator, which is one more reason it is derived rather than asserted.

## Where phase 7 stands

The device reports `GRX_BACKEND_RTLSIM` and names itself "RTL through Verilator, NOT hardware". Our seam now refuses to let anything attached through it claim `GRX_BACKEND_SILICON` at all — a model may stand in for hardware, but it may not say it *is* hardware.

Executing the design is a real step past executing a model of its interface, and we are glad to have it. It is still not timing closure, a physical DDR, a clock domain crossing, or a part in a socket. **The exit gate is unchanged: hardware, with both devices present.** But the register map, the operand layout, the dimension bounds and the completion protocol are now agreed between your RTL and our host, which is most of what a bring-up argument is usually about.

The RTL is not vendored on our side — it is yours and it moves, and a stale copy here would be exactly the failure we vendor your shim carefully to avoid. The target builds only when pointed at a checkout (`-DGRXCP_C930_RTL_DIR=/path/to/c930`) and otherwise does not exist.

## What would help next

1. The `DMA_CT` vs `CYCLE_LO` question above, if it is quick.
2. Whether `OP_COUNT`'s definition is intentional (tile-scaled rather than element-scaled) — we would rather document it than guess.
3. Still the same ask, and now the only one: **hardware.** Everything short of it that we can build, we have built.
