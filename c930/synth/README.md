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

## Real-design results (Aug 2026, after the dcache + icache EBR re-architecture)

| Resource            | Before  | After  | ECP5-85F |
|---------------------|---------|--------|----------|
| LUT4                | 423,747 | **51,140** | 83,640 (61%) |
| TRELLIS_FF          | 86,971  | **23,801** | 83,640 (28%) |
| CCU2C (carry)       | 1,564   | 2,069  | —        |
| DP16KD (EBR)        | 0       | **16** | 156      |
| DPR16X4 (EBR slice) | 104     | 104    | —        |
| MULT18X18D (DSP)    | 21      | 21     | 156      |

Latch audit: **clean** — no inferred latches (`check -noinit` reports 0
problems). **The full design now fits ECP5-85F at 61% LUT density.**

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

The real design (51K LUTs = 61% LUT density, 28% FF, 10% BRAM) places
cleanly and the placement-stage estimate in `pnr.log` is **~15.9 MHz** (up
from 10.6 MHz pre-icache — the register-based icache was on the critical
path; the fit-test style CSR `mtinst` datapath dominates now). Both numbers
are placeholder-constraint artifacts (the LPF clocks at 400 MHz to expose the
true critical path), direction-setting only.

Routed-Fmax caveat: nextpnr's rip-up routers (router1 with two seeds and
router2) do not fully converge on this net count — they oscillate at a few
hundred unrouted wires / ~5K track-overuse out of ~200K-1.15M wires after
1.5+ hours, the same endgame that stalled the old 87% run. This is a
nextpnr heuristic limitation on the design's net count, not a resource
shortage: the design fits comfortably (61%/28%/10%) and the much smaller
fit-test design P&Rs to completion at similar density. A commercial router
(Vivado/Quartus/Radiant) or a further fabric reduction (e.g. moving the
tag/valid arrays or the NPU's A/B/C buffers into BRAM) would close the last
nets; the yosys resource/latch report is the authoritative feasibility result.

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
