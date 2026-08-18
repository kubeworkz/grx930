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

## Real-design results (Aug 2026, after the dcache EBR re-architecture)

| Resource            | Before  | After  | ECP5-85F |
|---------------------|---------|--------|----------|
| LUT4                | 423,747 | **73,161** | 83,640 (87%) |
| TRELLIS_FF          | 86,971  | **56,505** | 83,640 (68%) |
| CCU2C (carry)       | 1,564   | 2,069  | —        |
| DP16KD (EBR)        | 0       | **8**  | 156      |
| DPR16X4 (EBR slice) | 104     | 104    | —        |
| MULT18X18D (DSP)    | 21      | 21     | 156      |

Latch audit: **clean** — no inferred latches (`check -noinit` reports 0
problems). **The full design now fits ECP5-85F.**

### What changed

The 423K-LUT blow-up was the **dcache write path**: the old memory demoted to
registers with per-bit byte-strobe/AMO write muxes (365,988 LUTs standalone).
The re-architecture (`riscv_core_dcache_memory.sv`) uses EBR-mappable
semantics — a single write port with 32 decoded byte-lane enables, a
registered read port, and a `LOAD_DONE` controller state — so the storage maps
to **8 DP16KD**:

- dcache standalone: 365,988 -> **9,008 LUTs / 3,471 FFs / 8 DP16KD**
- icache standalone: 28,165 LUTs (still register-based; same treatment would
  shrink it further, but it is not the bottleneck)

Behavior was verified unchanged: the full 22-case SoC sweep (core + MMIO +
DMA + DDR, incl. GEMM shapes, AMO/LR-SC stress, store-ordering, traps) and the
hazard-unit unit test both pass with the refactored cache.

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
logic-fabric estimate for the pre-refactor design; with the dcache now in EBR
the real design fits directly (see below).## Fmax (real design P&R)

The real design (73K LUTs = 87% density) places cleanly (`make synth` runs
nextpnr after yosys). At that density the ROUTER does not fully converge in
reasonable time (it oscillates at ~200-300 unrouted wires out of ~340K, the
same endgame that stalled the old 90% fit test), so there is no final routed
Fmax yet. The placement-stage estimate in `pnr.log` is **~10.6 MHz**
(pre-routing, dominated by the still register-based icache fabric); the
routable fit-test (63% density) measured ~20 MHz. Both numbers are
placeholder-constraint artifacts (the LPF clocks at 400 MHz to expose the
true critical path), direction-setting only.

The clean path to a routed real-design Fmax is to give the icache the same
EBR treatment as the dcache (~28K LUTs / 35.5K FFs of register storage to
move into DP16KD) -- that drops density below ~60% and the router finishes
in minutes (as the fit test proved).

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
| `cache_probe.ys` / `dcache_probe.ys` | per-hierarchy LUT attribution probes |

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
