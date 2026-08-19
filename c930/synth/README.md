# C930 SoC synthesis (Yosys + nextpnr, ECP5)

Zero-hardware FPGA feasibility flow for `c930_soc_top`, using the vendored
**oss-cad-suite** under `c930/toolchain/` (portable; download the release and
extract it there).

## Usage

```bash
make synth        # real design: yosys resource/latch report + nextpnr P&R -> Fmax
make synth-fit    # cache-shrunk fit test (kept as a historical comparison)
```

Both wrap `synth/run_synth.sh` (`fit` selects the fit variant). Logs and
netlists land in `c930/build/synth/`.

## Real-design results (Aug 2026, after both caches EBR-mapped AND P&R-complete)

| Resource            | Before  | After  | ECP5-85F |
|---------------------|---------|--------|----------|
| LUT4 (logic)        | 423,747 | **35,074** | 83,640 (42%) |
| TRELLIS_FF          | 86,971  | **10,619** | 83,640 (13%) |
| CCU2C (carry)       | 1,564   | 2,069  | —        |
| DP16KD (EBR)        | 0       | **16** | 156      |
| DPR16X4 (EBR slice) | 104     | **416** | ~20K    |
| MULT18X18D (DSP)    | 21      | 21     | 156      |

Latch audit: **clean** — no inferred latches in the final netlist (0 `$dlatch`,
0 DLATCH cells; `check -noinit` reports 0 problems). **The full design P&Rs
to completion at 42% LUT density with a routed Fmax of ~26.4 MHz (default
nextpnr router).**

### What changed

The 423K-LUT blow-up was the **cache write paths**: the old memories demoted
to registers with per-bit byte-strobe/AMO write muxes (dcache 365,988 LUTs
standalone). Both caches now use EBR-mappable semantics — a registered read
port, a decoded byte-lane/whole-line write port, and a controller state that
stalls the core one cycle per read so the registered data is sampled:

- dcache standalone: 365,988 -> **9,008 LUTs / 3,471 FFs / 8 DP16KD**
  (`LOAD_DONE` state; 32 decoded byte-lane enables; array has no reset —
  `VALID_MEM` gates every read, which is what lets EBR storage be used).
- icache standalone: 28,165 LUTs / 35,517 FFs -> **7,808 LUTs / 2,813 FFs /
  8 DP16KD** (same registered-read pattern; fill writes a whole line).

The icache's `LOAD_DONE` state also **holds** (stall released, word still
presented) until the fetch PC advances — i.e. until the pipeline actually
captured the instruction. Without the hold, the icache's period-2 hit-stall
loop and the dcache's period-2 registered-read loop phase-lock in anti-phase
and deadlock the pipeline (no cycle ever has both stalls released).

Moving the icache storage into EBR also exposed a latent hazard-unit bug: the
one-cycle CSR-dependency stall pulse was consumed invisibly when it coincided
with a cache stall, so a CSR producer never advanced MEM->WB and a dependent
instruction (e.g. the trap handler's `addi` on `csrr mepc`) computed with a
stale operand — corrupting `mepc` and sending `mret` to a garbage address.
The pulse tracker now only advances when the pipeline can actually move, so
the pulse re-fires after any cache/M-extension stall (`riscv_core_hazard_unit`).

### Tag arrays into distributed RAM (DPR16X4)

The controllers' `TAG_MEM` (128 x 52 per cache) was being demoted to ~6.6K
FFs per cache even though it has no reset, because it was written in the same
`always_ff` as the async-reset `VALID_MEM` clear — yosys demotes every memory
written from an async-reset-sensitive block. Splitting the TAG write into its
own no-reset block maps it to distributed RAM (a line is only trusted when
`VALID_MEM` says so, so stale tags are never observable):

- icache standalone: 28,165 -> 7,808 -> **2,735 LUTs / 253 FFs**
  (8 DP16KD + 80 DPR16X4)
- dcache standalone: 365,988 -> 9,008 -> **8,615 LUTs / 911 FFs**
  (8 DP16KD + 40 DPR16X4)

This is what finally let the real-design router finish: the net count dropped
enough that nextpnr's rip-up router converges (it had oscillated for hours at
61% density).

Behavior was verified unchanged: the full 22-case SoC sweep (core + MMIO +
DMA + DDR, incl. GEMM shapes, AMO/LR-SC stress, store-ordering, the two-trap
illegal+ecall test) and the hazard-unit unit test both pass with the refactored
caches.

## The DDR placeholder (c930_ddr_stub.sv)

The behavioral `c930_ddr.sv` (64 KB byte array) must not be synthesized (it
demotes to ~hundreds of K FFs), and nextpnr cannot place a blackbox. The stub
keeps the module name/ports and implements a **genuine 16-line x 256-bit
memory**: dcache writes and AXI writes land in it, and every read port returns
stored state. That is deliberate:

- A stub whose read data is a function of the request address lets yosys prove
  `INSTR_MEM[i] == f(i)` and collapses the cache arrays; one that discards the
  AXI write data lets yosys prove the systolic array's C-write path is
  unobservable and folds the NPU (21 -> 2 DSPs, u_npu -> ~600 FFs). Both bugs
  were reproduced and ruled out. The memory stub keeps every datapath live
  (21 DSPs, full icache) while adding only ~7K LUTs / 1.7K FFs of placeholder.

## Fit test (`make synth-fit`)

Kept for comparison. Shrinks the caches via `chparam` (INDEX_WIDTH 7->3)
through the `ICACHE_INDEX_WIDTH`/`DCACHE_INDEX_WIDTH` parameters on
`riscv_core_top` (added so cache geometry is settable per board). Result
(P&R complete): **52,897 LUTs (63%), 7,104 FFs, 2 DSPs**, Fmax ~20 MHz with
the CSR unit's `mtinst` datapath on the critical path. This was a
logic-fabric estimate for the pre-refactor design; with both caches now in EBR
the real design fits at 61% and P&Rs directly (see below).

## Fmax (real design P&R)

**The real design now P&Rs to completion** (`make synth`; default nextpnr
router1): after the tag arrays moved to DPR16X4 the net count dropped enough
that the router converges (it had oscillated for 1.5+ hours at the 61%-density
build). The routed result in `pnr.log` / `ecp5.config` (full bitstream config):

- **Routed Fmax: ~26.4 MHz** (constrained at 400 MHz to expose the true
  critical path). Direction-setting, not a board-validated number.

### M/D operand retiming (Aug 2026)

The routed critical path (38.7 ns) threaded the MUL/DIV unit's combinational
carry chains: ex_mem ALU result -> dcache valid/tag -> srcB mux -> ALU ->
MUL/DIV's 64-bit CCU2C subtractor -> fetch-PC mux -> CSR `mepc`. The fix in
`riscv_core_mul_div.sv`:

- `srcA`/`srcB` are captured into registers at issue (they are stable for the
  whole op because EX is frozen by the m-busy stall).
- The booth/non-restoring start pulses are delayed one cycle so the datapath
  samples the registered operands; the control FSM stays on the raw operands
  (its fast-path comparisons are short and resolve in the issue cycle).
- The `mul_in`/`div_in` sign-prep, the booth accumulator, and the
  non-restoring subtractor now start from the operand registers instead of a
  chain from the core's srcB mux. Cost: one extra stall cycle per M/D op
  (65 vs 64) and +130 FFs.

Verified: full 22-case SoC sweep + hazard-unit test pass. Result: the
MUL/DIV units no longer appear in the critical path report (the tail is now
`src_b_mux -> ALU adder -> fetch-PC -> CSR mepc`, still ~26 ns routing), and
the routed Fmax moved **25.8 -> 26.4 MHz**. The next bottleneck is the ALU
adder fed by the load-use forward; a one-cycle load-use stall (registered WB
forward) or pipelining the MMIO bridge read would attack it directly.

## Files

| File | Purpose |
|------|---------|
| `synth.ys`          | real-design flow body (yosys only) |
| `synth_fit.ys`      | fit-test flow (chparam caches + DDR stub + P&R) |
| `run_synth.sh`      | drives yosys/nextpnr via `cmd` (oss-cad-suite is MSYS2-built; Git Bash direct exec -> 127) |
| `light.abc`         | minimal abc mapping script (default resyn OOMs on the ~100K-FF netlist) |
| `ecp5_85f.lpf`      | placeholder pin/clock constraints (400 MHz target reveals true Fmax) |
| `c930_ddr_blackbox.sv` | synth-only blackbox for the behavioral DDR (opaque reference) |
| `c930_ddr_stub.sv`     | tiny synthesizable DDR placeholder (genuine 16-line memory; keeps datapaths live) |
| `cache_probe.ys` / `icache_full.ys` / `dcache_full.ys` | per-hierarchy LUT/EBR attribution probes |

## Bugs the synthesis run caught (all fixed, RTL now clean for yosys)

- TAG_MEM demoted to registers because it was written in the same
  async-reset `always_ff` as the VALID_MEM clear — split into a no-reset
  block in both cache controllers (maps to DPR16X4).

- `mepc` multiply-driven by two `always_ff` blocks (blocking `=` + non-blocking
  `<=`) — Icarus tolerated it; nextpnr flagged it; consolidated.
- ALU `o_alu_resultword` inferred a benign latch in the 64-bit path — defaulted.
- Enum initializers on the same line as the declaration (dcache/icache
  controllers) — yosys parser rejected; split.
- `$time == 0` probe in `riscv_core_icache_controller.sv` — sim-only; guarded
  with `` `ifndef SYNTHESIS `` (yosys defines it automatically).
- Unpacked-array ports `i_act`/`i_ps_in` in the systolic array — flattened to
  packed vectors (Icarus 11 also misconnects these).
- Cache tops did not pass `INDEX_WIDTH` down to their controller/memory
  modules (latent size-mismatch wart) — now parameterized through
  `riscv_core_top` (`ICACHE_INDEX_WIDTH`/`DCACHE_INDEX_WIDTH`, defaults 7).
- dcache `wr_nbytes` was 3 bits, truncating dword writes (`3'd8` -> 0 byte
  enables) after the EBR re-architecture — widened; caught by the SoC sweep.
- CSR-dependency stall pulse consumed by overlapping cache stalls (mepc
  corruption in the trap handler) — the pulse tracker now re-arms after any
  cache/M-extension stall; caught by the SoC sweep with the icache hit-stall.
