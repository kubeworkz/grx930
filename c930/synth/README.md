# C930 SoC synthesis (Yosys + nextpnr, ECP5)

Zero-hardware FPGA feasibility flow for `c930_soc_top`, using the vendored
**oss-cad-suite** under `c930/toolchain/` (portable; download the release and
extract it there).

## Usage

```bash
make synth        # real design: yosys resource/latch report (~15 min)
make synth-fit    # cache-shrunk fit test: yosys + nextpnr P&R -> Fmax (~30 min)
```

Both wrap `synth/run_synth.sh` (`fit` selects the fit variant). Logs and
netlists land in `c930/build/synth/`.

## What the real-design run reports (as of Aug 2026)

| Resource            | Count   | ECP5-85F |
|---------------------|---------|----------|
| LUT4                | 423,747 | 83,640 (511%) |
| TRELLIS_FF          | 86,971  | 83,640 (103%) |
| CCU2C (carry)       | 1,564   | —        |
| DPR16X4 (EBR slice) | 104     | —        |
| MULT18X18D (DSP)    | 21      | 156      |

Latch audit: **clean** — no inferred latches (all `done_latch`/memory signals
resolve to proper registers; `check -noinit` reports 0 problems).

**The full design does not fit ECP5-85F**, and the reason is precise:

- `riscv_core_dcache_top` alone: **365,988 LUTs / 35,655 FFs**
- `riscv_core_icache_top` alone:   **28,165 LUTs / 35,517 FFs**

Both caches store the same 128 x 256-bit lines, so the FF counts are nearly
equal — the LUT blow-up is the dcache's **per-bit byte-strobe / AMO write
muxes** (a 256-bit line written at any of 32 byte lanes, with 4 sizes + AMO +
line-fill cases). That pattern defeats EBR inference (async-read, per-bit
write enables), so every RAM bit becomes a flop plus a giant mux tree.

### Fix direction (before any board purchase)

Re-architect the dcache memory toward EBR-mappable semantics: registered
(or at least shared) read/write ports, a decoded per-word byte-enable vector
computed once instead of per bit, and a single-port line-fill/write interface.
The DP16KD primitive has native byte-enables; the write-mux cost then moves
into BRAM and the LUT count drops by ~350K.

## Fit test (`make synth-fit`)

nextpnr cannot place a 511%-over design, so the fit test shrinks the caches
via `chparam` (INDEX_WIDTH 7->3, i.e. 128 -> 8 lines) through the new
`ICACHE_INDEX_WIDTH`/`DCACHE_INDEX_WIDTH` parameters on `riscv_core_top`
(added so cache geometry is settable per board). The behavioral DDR model is
replaced by a tiny synthesizable placeholder (`c930_ddr_stub.sv`; nextpnr
cannot place blackboxes).

Result (P&R complete):

- **52,897 LUTs (63%), 7,104 FFs, 2 DSPs** — fits ECP5-85F.
- **Fmax ~20 MHz** (16.2 MHz best-effort / 20.3 MHz after rip-up). The
  critical path is in the CSR unit's `mtinst` datapath: only ~7.6 ns of logic
  but ~29 ns of routing — placement is scattered by the residual cache-mux
  fabric, so routing dominates. Expect this to improve sharply once the dcache
  is re-architected (and a real clock is used instead of the placeholder IO).

This is a **logic-fabric Fmax estimate, not the real design's Fmax** — the
caches in the fit test are 8 lines, and the systolic PE multipliers map to
LUTs rather than DSPs under chparam re-elaboration (real design infers 21
DSPs). Treat both numbers as direction-setting until the dcache lands in BRAM.

## Files

| File | Purpose |
|------|---------|
| `synth.ys`          | real-design flow body (yosys only) |
| `synth_fit.ys`      | fit-test flow (chparam caches + DDR stub + P&R) |
| `run_synth.sh`      | drives yosys/nextpnr via `cmd` (oss-cad-suite is MSYS2-built; Git Bash direct exec -> 127) |
| `light.abc`         | minimal abc mapping script (default resyn OOMs on the ~100K-FF netlist) |
| `ecp5_85f.lpf`      | placeholder pin/clock constraints (400 MHz target reveals true Fmax) |
| `c930_ddr_blackbox.sv` | synth-only blackbox for the behavioral DDR (real report) |
| `c930_ddr_stub.sv`     | tiny synthesizable DDR placeholder (fit/P&R) |
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
