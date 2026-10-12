# PLAN B — Netlist Rework Proposal

**Design:** `grx930_test_chip` (GRX930 stripped test chip: 1× RV64IMAC + 8 KB SRAM + UART)
**Target:** wafer.space GF180MCU **1×1 slot** — die 3930×5120 µm, core ≈ 19.93 mm², 5LM (gf180mcuD, mcu7t5v0)
**Date:** 2026-09-30 · Branch: `npu/shot-floor`

---

## 1. Why plan B — the evidence

All four DRT attempts failed. The final attempt (step 53, M1 as bottom routing
layer) was the last cheap structural variable and it was **falsified**:

| DRT attempt | Setup | Outcome |
|---|---|---|
| 1 (step 48) | Metal2 bottom | OOM at 60% iter 0, swap exhausted, 6h55m |
| 2 (step 49) | guides @ 144% GRT usage | iter0 **22.8M** violations → iter1 **25.5M** (diverging) |
| 3 (step 51) | GRT fixed to 103% | killed @ 70% iter0 — statistically identical curve to doomed run |
| 4 (step 53) | **+ RT_MIN_LAYER=Metal1** | 10% = 0 → **20% = 3,115,323** → 30% = 7,197,279 → **OOM-killed @ 40%** |

Fast-abort contract (20% checkpoint vs doomed reference 1,881,923): **1.66× worse.**
The M1-bottom hypothesis made the curve *worse*, not orders of magnitude better.

**Root cause (unchanged):** `design__instance__utilization = 84.35%`
(16.81 mm² of cells in a 19.93 mm² core, 722,223 instances, 0 macros) — the netlist
is ~2.8× too large for this die on 5LM. GRT total reached 92.66% with per-layer M2
overflow even after every flow knob was already spent:

- `SYNTH_STRATEGY` already `AREA 3` (max area) · `FP_CORE_UTIL 30` · `PL_TARGET_DENSITY_PCT 65`
- `GRT_ADJUSTMENT 0.0`, `RT_MIN_LAYER Metal1`, `GRT_ALLOW_CONGESTION true` — all tried
- No Metal6 on gf180mcuD 5LM; die size fixed by the shuttle slot

**Flow-level knobs are exhausted. Only the netlist can change.**

Empirical calibration (from `estimate_gf180mcu_area.py`, wafer.space Run 1 density
report): every design that ever routed on this shuttle ran at **3k–22k cells/mm²**
(best: Cloneless1, 22k @ 44% util). We are at **36k cells/mm²** — 1.6× denser than
the best-ever, and the theoretical library max is 50k. **Gate: ≤ 15k cells/mm²
(≈ 300K placed cells, ≈ 30% util) to be safely inside the proven envelope.**

## 2. Where the cells actually are (measured)

Sources: `RUN_2026-09-24_04-18-20/06-yosys-synthesis/reports/stat.rpt` (flat,
post-abc, real run) and a hierarchy-preserving probe (`synth -noabc`, per-module
`stat`) run 2026-09-30 — reproduction in §7.

Flat netlist (real run): **520,182 cells · 12.02 mm² yosys area · 92,632 FFs**
(49.5% of area is sequential). After P&R: 722,223 instances, 16.81 mm² (+4.8 mm² of
inserted buffers/CTS/diodes — congestion itself).

Per-module (hierarchy-preserving probe, generic cells, total 380,083):

| Module | Cells | Share | What it is |
|---|---:|---:|---|
| **`grx930_sram_64kb`** | **271,546** | **71.4%** | 8 KB FF array: 65,536 DFFs + ~205K cells of 1024:1×256-bit read mux / write decode |
| `riscv_core_dcache_memory` | 20,225 | 5.3% | 1 KB D-cache data array (FF) + mux |
| `riscv_core_csr_unit` | 18,916 | 5.0% | CSR / MMIO registers |
| `riscv_core_icache_memory` | 17,775 | 4.7% | 1 KB I-cache data array (FF) + mux |
| `riscv_core_icache_controller` | 8,584 | 2.3% | tag mem + FSM |
| `riscv_core_dcache_controller` | 7,065 | 1.9% | tag mem + FSM |
| `riscv_core_rf` | 6,242 | 1.6% | 32×64 register file + decode |
| **Memory system subtotal** | **~325,200** | **~85.6%** | SRAM + caches + their controllers |
| Everything else (CPU core, UART, top glue) | ~48,600 | ~12.8% | ALU, Booth mul, div, pipeline, decode, CSR top-level, UART |

**The entire non-memory SoC is ~49K cells.** The memory-as-standard-cells
implementation is the netlist. (Boot ROM module `c930_bootrom` is *not
instantiated* — dead RTL, no action needed.)

Area attribution (flat run, ∝ cell share): SRAM ≈ 8.5 mm² (4.2 mm² FF + ~4.3 mm²
mux/decode), caches+controllers ≈ 1.7 mm², CPU+UART+glue ≈ 1.8 mm².

## 3. Options

### Option A — Replace the 8 KB FF-SRAM with a real SRAM macro (OpenRAM) ★ endgame

- **Remove:** ~271,546 cells (71%) → flat synth ≈ 150K cells + 1 macro.
- **Add:** GF180 OpenRAM 64 Kbit macro, est. 0.5–1.0 mm² (Run-1 data: 4 Kbit ≈ 0.023 mm²
  core + periphery).
- **Estimated result:** placed ≈ 190–230K cells, cell area ≈ 5 mm² → **util ≈ 25%** ✅
- **Config path exists:** OL2 macro flow steps already present in the run
  (`11-openroad-checkmacroinstances`, `16-openroad-manualmacroplacement`), `MACROS` +
  `FP_MACRO_PLACEMENT` in config.json. `design__instance__count__macros` is currently 0.
- **RTL work:** keep the module's external contract (2-cycle read, 256-bit line,
  byte-strobe write) and implement it on the macro inside `grx930_sram_64kb`.
  Two ways: (a) generate a **256-bit-wide** macro (256×256) so the line read stays
  single-cycle-behind-the-register; or (b) generate 64/128-bit and burst 4 beats
  internally, reassembling the line before pulsing `o_rd_done` — requires care
  because controllers assume the fixed 2-cycle latency.
- **Effort:** 2–4 days. OpenRAM install on the server (network + python deps),
  macro generation, LEF/GDS/LIB views, PDN straps over the macro, antenna, LVS/DRC
  of the macro hardener, STA of the macro lib.
- **Risks:** first-time macro flow on this box; pin access layers on 5LM; macro
  placement strategy (center or flank; keep over-macro routing off M1/M2 pins).

### Option B — Shrink the FF memories in RTL (no new tooling) ★ first move

- **Change:** SRAM `DEPTH 1024 → 256` (8 KB → 2 KB, aliasing/wrap already defined in
  RTL: addresses ≥ depth wrap) and caches `INDEX_WIDTH 5 → 4` (1 KB → 512 B each).
- **Remove:** ≈ 49K FFs + ≈ 150K mux/decode cells (mux tree scales with depth) + ≈ 22K
  cache cells → **flat synth ≈ 160–190K cells** (down from 380K generic / 520K flat).
- **Estimated result:** placed ≈ 250–300K, cell area ≈ 6–7.5 mm² → **util ≈ 30–37%**
  — inside the Run-1 shipped envelope (44% shipped) but above the 30% comfort line.
  GRT gate (§6) decides.
- **Effort:** **hours** — two parameter edits, then the existing yosys probe (§7) to
  measure before burning a flow run. No new IP, no PDK work.
- **Risks:** firmware must fit 2 KB (wrap semantics already exist, but boot/data
  layout must be re-verified in simulation); if GRT gates still fail, tighten to
  1 KB (`DEPTH 128`) and/or 512 B caches and re-probe — each halving is linear.
- **Option B′ (more aggressive):** also delete the caches entirely (feed the core's
  memory port straight to the SRAM). Removes ~79K array cells + 15.6K controller
  cells; medium RTL rework (fetch path); performance irrelevant at 25 MHz
  (CLOCK_PERIOD 40 ns). Hold in reserve.

### Option C — Small fries (do only if a few % is all that's missing)

- `riscv_core_csr_unit` at 18,916 cells is suspiciously large for a CSR file —
  worth a look; if it holds MMIO window regs, trim.
- Booth multiplier: split 64×64 into two 32-bit cycles — saves ~3–5K cells; timing
  is trivial at 40 ns. Low value, low risk.
- `riscv_core_rf` (6,242) is fine as-is.

**No config-only option exists** (proven by four failed attempts).

## 4. Expected outcomes

| Scenario | Flat synth cells | Placed cells (est.) | Cell area (est.) | Util (est.) | In proven envelope? |
|---|---:|---:|---:|---:|---|
| Current | 520,182 | 722,223 | 16.81 mm² | **84.4%** | ❌ 1.6× beyond best-ever |
| **B (8→2 KB, caches halved)** | ~220–240K | ~250–300K | 6–7.5 mm² | **30–37%** | ✅ (gate on GRT) |
| **B-aggressive (1 KB SRAM)** | ~180K | ~220K | ~5.8 mm² | **~29%** | ✅ |
| **A (OpenRAM 8 KB macro)** | ~150K + 1 macro | ~190–230K | ~5 mm² | **~25%** | ✅✅ |
| **A + B combined** | ~110K + 1 macro | ~150K | ~4 mm² | **~20%** | ✅✅✅ |

## 5. Recommended path

1. **Phase 0 — measure (done):** per-module breakdown above; harness in §7.
2. **Phase 1 — Option B (hours):** edit `grx930_test_chip.sv` (`DEPTH`), 
   `riscv_core_top.sv` (`INDEX_WIDTH` 5→4); re-run the yosys probe.
   **Gate: flat cells ≤ 240K and yosys area ≤ 6.0 mm²** — else go B-aggressive
   (DEPTH 128) and re-probe.
3. **Phase 2 — full OL2 run (fresh tag, RTL changed → no resume):** ~6–10 h to the
   DRT decision point, with the §6 gates. Reuse `watch_v7.sh` (point it at the new
   step dir).
4. **Phase 3 — only if Phase 2 fails its GRT gate, or the demo needs the full 8 KB:**
   Option A (OpenRAM). Don't pay the macro-flow cost preemptively — B reaches the
   envelope for hours of work, and A stays available as the upgrade.

## 6. Re-run plan and abort gates

- **Fresh run tag** (RTL changed; do not resume `RUN_2026-09-24_04-18-20`).
- **GRT gate (before letting DRT burn ~7 h):** total usage ≤ 90 % **and every layer
  ≤ 100 %** (no `GRT-0115` overflow warning, no M1/M2 overflow). Current best was
  92.66 % total with M2 at 103.57 % — that failed.
- **DRT fast-abort (same contract as attempt 4):** first flushed
  `Completing 20%` must be **< 50,000 violations** (attempt 4: 3,115,323;
  doomed run: 1,881,923). Millions → kill the container immediately.
- **Monitoring:** reuse `watch_v7.sh` — set `L=` to the new DRT log path; heartbeat
  + alert files as before. Note: never `pkill -f <script-name>` from an ssh command
  line that contains the script name (it kills the ssh session itself).
- **Resources:** disk 13 GB free after `ol2_grx930_v7` removal (enough for one
  container); RAM 14.7 GB free — coordinate with the `verilator_bin` jobs that
  consumed ~15 GB on the box during attempt 4's final minutes (they contributed to
  the OOM environment).

## 7. Reproduction — measurement harness (kept on server)

```sh
# per-module cell attribution (hierarchy preserved, no abc) — ~1 min
B=/home/ubuntu/grx930_ol2/build
mkdir -p $B/planb2 && cp /home/ubuntu/grx930_ol2/openlane2_rtl/src/*.sv $B/planb2/
sed -i '/readmemh/d' $B/planb2/c930_bootrom.sv   # boot.hex absent on server; module is un-instantiated anyway
docker run --rm --entrypoint /bin/sh -v /home/ubuntu/grx930_ol2:/work \
  ghcr.io/efabless/openlane2:2.3.10 -c \
  'cd /work/build/planb2 && set -- *.sv && yosys -p \
   "read_verilog -sv \$*; hierarchy -check -top grx930_test_chip; synth -top grx930_test_chip -noabc; stat"' \
  > $B/planb2_synth.log 2>&1
awk '/^=== /{m=$2} /Number of cells:/{print $NF, m}' $B/planb2_synth.log | sort -rn
```

Data sources for every number above:
- Flat netlist stats: `runs/RUN_2026-09-24_04-18-20/06-yosys-synthesis/reports/stat.rpt`
- Placement metrics: `runs/RUN_2026-09-24_04-18-20/52-openroad-globalrouting/state_out.json`
  (`design__instance__count` 722223, `design__instance__area` 16808300,
  `design__instance__utilization` 0.843549, `count__macros` 0)
- DRT curves: `53-openroad-detailedrouting/openroad-detailedrouting.log`
  (attempt 4), `49-`/`51-` logs (attempts 2/3)
- Density envelope: `c930/asic_gf180mcu/estimate_gf180mcu_area.py` (Run 1 report)

## 8. Risks / open questions

1. **Firmware footprint vs 2 KB SRAM** — must be checked against the test firmware
   before committing to B; 4 KB (`DEPTH 512`) is an intermediate step
   (est. util ~40%, marginal).
2. **OpenRAM/GF180 first-timer risk** if Phase 2 gates fail → budget the 2–4 days.
3. **`csr_unit` anomaly** — 18.9K cells may hide an easy 10–15% logic win.
4. **Verilator jobs on the shared box** can re-create the OOM environment; pin or
   pause them before a DRT run.5. Header comments in `grx930_test_chip.sv` still say "0.5×1 slot / 4.46 mm² core"
   and "2KB caches (BRAM-based)" — stale; actual config is the 1×1 slot with FF
   arrays. Worth correcting while editing RTL.
6. **Pre-existing cache index/tag decomposition bug — FIXED and re-verified**
   (found during Option B, present BEFORE the shrink). The controllers indexed
   `TAG_MEM`/`VALID_MEM` with the fixed 7-bit macros `` `define ICACHE_INDEX
   11:5 `` / `` `define DCACHE_INDEX 11:5 `` while the data arrays used
   `` [11 -: INDEX_WIDTH] ``; they agree only at `INDEX_WIDTH = 7`. At the chip's
   width 4 the tag array had 16 entries selected by 7 bits, so 8 tag entries
   aliased onto one data line: filling entry B left entry A `VALID` over B's
   data, and A's next access **hit with the wrong line**. Simulation masked it
   as a slow always-miss only in the cases where the out-of-range tag read
   returned X; the alias hit above is real and wrong in both sim and silicon.

   **Fix (parameterised split, no magic widths):** index `addr[5 +: INDEX_WIDTH]`
   and tag `addr[ADDR_WIDTH-1 : 5+INDEX_WIDTH]` in *both* the tag and the data
   arrays; tag storage width derived as `TAG_W = ADDR_WIDTH-5-INDEX_WIDTH` rather
   than taken from `TAG_WIDTH`; the tops pass that down and default `TAG_WIDTH`
   to the derived value; `riscv_core_top` no longer hardcodes `.TAG_WIDTH(52)`.
   A sim-only guard `$error`s if an explicit `TAG_WIDTH` disagrees with the
   split. Files: `openlane2_rtl/src/riscv_core_{icache,dcache}_{controller,
   memory,top}.sv` + `riscv_core_top.sv`. At `INDEX_WIDTH = 7` the tag width is
   unchanged (52) and the netlist is logically identical; at 4 the tag array
   gains 3 bits/entry (+48 flops per cache, ~0.01% of the 6.66 mm² cell area).

   **Evidence** (`c930/tb/`): `tb_icache_index_alias.sv` +
   `tb_dcache_index_alias.sv` (A = 0x0000, B = 0x00A0 share the buggy
   `addr[11:8]` index but differ in the correct `addr[8:5]`; the TB also asserts
   every fill request is line-aligned and matches the requested line) run by
   `run_cache_index_alias.sh` against both RTL trees:
   pre-fix `RESULT: FAIL … got 000000a0 expected 00000000 (wrong line served on
   HIT)`, fixed `RESULT: PASS … fill addresses decomposed correctly`, runner exit
   1 → 0. `run_tag_width_guard.sh` proves the guard is live (silent on the derived
   default; fires on the pre-fix `TAG_WIDTH=52` at width 4). `verify_cache_fix.sh`
   adds the flow's own gates: verilator lint of `grx930_test_chip` 0 errors both
   trees with `%Warning-WIDTHTRUNC` down 21 → 7 and no new warning type, and
   yosys `synth -run coarse` shows the same `$mem_v2` inventory before/after
   (`TAG_MEM` + `INSTR_MEM`/`DATA_MEM` still infer as memories; `VALID_MEM` →
   registers in both, by design).

   **Not covered:** there is no testbench for `grx930_test_chip`
   (`asic_gf180mcu/Makefile`'s `sim` target references a `../tb/tb_grx930_test_chip.sv`
   that does not exist), so the chip-level run is lint + synthesis only. The same
   literal-split pattern also exists in the sibling core trees
   (`rv64imac/RTL/`, `rv64imac/RTL/caches/`, `rv64imac/FPGA/src/`, and
   `asic_gf180mcu/grx930_test_chip.sv` at width 5) where it is *dormant* only
   because nothing instantiates them below `INDEX_WIDTH = 7`; they were left
   unchanged. **Netlist impact:** the fix changes the RTL, so any pre-existing
   synthesis result is a pre-fix netlist (the in-flight `slotcore_v1` run
   synthesized at 20:16:51, before these edits, and stays valid for the A/B);
   final PPA/DRC/LVS numbers need a fresh synthesis.

7. **MMIO read-data hold latch — ported from the reference tree** (2026-10-11,
   `riscv_core_dcache_top.sv`, the only file that changed). The same tree copy
   that carried the index bug also predated the 2026-10-03 fix in
   `rv64imac/RTL` described in `doc/dcache_mmio_read_hold.md`: an MMIO load
   frozen in `MMIO_RD_RETIRE` by an independent stall (an I-cache fill) sampled
   the *live* response bus to WB, so on a multi-core SoC a parked core's poll
   could hand it a zero. Ported as three pieces — the `mmio_rd_data_r/held`
   declarations, the `MMIO_RD_DATA_REG` latch with
   `i_mmio_read_done ? live : latched`, and `dcache_mux`'s third input — so the
   file is now functionally identical to the reference tree apart from the
   deliberate index/tag parameterisation.

   **Evidence:** `tb/tb_dcache_mmio_hold.sv` (the gate `make dcache_mmio_hold`
   names) run against the pre-port and ported trees with the same module list:
   `FATAL … 4 checks`, vvp exit **1** → `[PASS] … every check`, exit **0** (8
   PASS/4 FAIL → 13 PASS/0 FAIL). Unchanged by the port: the index/tag
   regressions still PASS (exit 0), the tag-width guard control still PASSes,
   verilator lint stays at 0 errors / 80 warnings over the same 7 types, and the
   caches still map to `$mem_v2`. The port costs exactly one 64-bit `$adff` and
   one `$mux` in the dcache top.   `tb/tb_dcache_mmio.sv` is byte-identical before
   and after (and fails on the reference tree too — a stale test, not a
   regression). **Netlist impact:** this is a second RTL change, so the fresh
   synthesis in item 6 now covers both.

8. **The chip has no boot path — tapeout blocker, not yet fixed.** Nothing in
   the tapeout tree instantiates a ROM: `hierarchy -top grx930_test_chip` drops
   `c930_bootrom.sv` and `bootrom_wrapper.sv` as unused (confirmed in the OL2
   netlist: `grx930_test_chip.nl.v` has a single module and no ROM), the chip's
   `CORE_RESET_PC` is `0x0`, and `grx930_sram_64kb` has no initial contents. So a
   part built from this netlist fetches whatever the SRAM powers up with, and
   `boot.hex` is a four-word NOP loop (the `$readmemh` path in
   `bootrom_wrapper.sv` even points at `/work/c930/...`, a container path that
   only exists during an OL2 run).

   **The boot testbench now demonstrates this**: `../tb/tb_grx930_test_chip.sv`
   loads its program into the SRAM itself (what a ROM would supply) and
   `make sim` reports `RESULT: PASS`; the same run with `+NO_PRELOAD` reports
   `RESULT: FAIL` with zero UART bytes and X in the SRAM — silicon's behaviour
   today. The test also catches the cache bug end-to-end: against the pre-fix
   tree (`rtl_before`) the banner still appears but the store/load-back reads
   `0x0` instead of `0x2A5A_1234`, while the fixed tree passes.

   A shuttle part needs a boot source: a ROM holding a real program (banner +
   self-test, not the NOP loop) mapped at a reset-visitable address, or a load
   path that can write the SRAM after reset. Either is a netlist change that
   needs its own synthesis — deliberately not done here.

9. **The cache index/tag parameterisation now covers every rv64imac copy.**
   The literals (`TAG 63:12`, `INDEX 11:5`, memory `11 -:`) are replaced by the
   derived split (`TAG = ADDR_WIDTH-1 : 5+INDEX_WIDTH`,
   index = `5 +: INDEX_WIDTH`) in all four cache trees under `rv64imac/`
   (`RTL`, `RTL/caches`, `RTL/caches/atomic_dcaches`, `FPGA/src`), with tag
   storage sized from the split (`TAG_W`) and a simulation `$error` if an
   explicit `TAG_WIDTH` disagrees. The tops derive the `TAG_WIDTH` default and
   pass `INDEX_WIDTH` down (the older copies previously left the controller and
   memory at the default 7 while claiming another width), and the three core
   tops that instantiate the caches pass a derived tag width. No netlist impact:
   the tapeout tree was fixed first; this keeps the reference trees from
   reintroducing the defect at any width. **Evidence:** the live tree passes the
   existing alias + guard regressions at `INDEX_WIDTH = 4` and the pre-fix
   staging fails them with the wrong-line signature
   (`addr=0: got 0xa0 expected 0x0`); the three older generations (Icarus cannot
   compile their packed 3-D memories — pre-existing, identical on the pre-fix
   sources) pass the new legacy regressions under Verilator at `INDEX_WIDTH = 4`
   and 6 with the guard firing for every controller; `rv64imac/RTL` elaborates
   under iverilog and `FPGA/src` under Verilator. Details, commands and the
   honest scoping of the older-generation control are in
   `../../doc/cache_index_tag_all_trees.md`.
