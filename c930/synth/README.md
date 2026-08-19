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
| LUT4 (logic)        | 423,747 | **34,012** | 83,640 (41%) |
| TRELLIS_FF          | 86,971  | **10,707** | 83,640 (13%) |
| CCU2C (carry)       | 1,564   | 2,101  | —        |
| DP16KD (EBR)        | 0       | **16** | 156      |
| DPR16X4 (EBR slice) | 104     | **416** | ~20K    |
| MULT18X18D (DSP)    | 21      | 21     | 156      |

Latch audit: **clean** — no inferred latches in the final netlist (0 `$dlatch`,
0 DLATCH cells; `check -noinit` reports 0 problems). **The full design P&Rs
to completion at 41% LUT density with a routed Fmax of ~31.9 MHz (default
nextpnr router, constrained at 400 MHz to expose the true critical path).**

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

- **Routed Fmax: ~24.3 MHz** (worst FF path 36.2 ns = 8.6 ns logic + 27.6 ns
  routing; constrained at 400 MHz to expose the true critical path).
  Direction-setting, not a board-validated number.

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
the routed Fmax moved **25.8 -> 26.4 MHz**. The next bottleneck was the ALU
adder fed by the combinational MEM->EX load-use forward.

### ID-based load-use stall (Aug 2026)

The old MEM->EX load forward put the dcache's address->data chain (tag/valid
decode, word select, MMIO decode) on the EX critical path. It is replaced by
an **ID-based one-cycle load-use stall** in `riscv_core_hazard_unit.sv`:

- A dependent in ID whose source matches a read-data producer (load/AMO/LR/SC,
  `resultsrc == 01`) in EX — or in MEM while the dcache is still servicing it
  (`dcache_stall`) — is held in ID (level-based) until the producer reaches WB.
  The value arrives through the **registered WB->EX forward**
  (`mem_wb_pipe_read_data -> result_wb`), so the dcache chain is off the EX
  data path entirely.
- The producer is never held: `stall_mem/wb` stay clear, so it flows
  EX->MEM->WB exactly as in the unstalled flow and the dcache's registered-read
  data window is never disturbed (an earlier EX-based pulse that held the load
  in MEM made the dcache re-enter its read path and corrupt the data).
- The `id_ex` pipe is flushed to a bubble while the producer sits in EX (the
  stall releases on the dcache's `LOAD_DONE` cycle, so the dependent enters EX
  exactly when the producer is in WB). The flush is deferred during cache/M
  stalls exactly like the branch flush. No operand-hold registers are needed:
  the dependent's operands are captured into the pipe only at the release
  edge, so they are always fresh.

Verified: full 22-case SoC sweep + hazard-unit test pass. Result: the dcache
address->data chain **no longer appears in the critical path report** — the
worst FF path is now `instr_wb -> CSR instruction decode (ip_stip) ->
op_result datapath -> mie/meie -> result_wb -> srcB mux -> ALU ->
i_csr_unit_pc -> mepc` (36.2 ns, mostly 27.6 ns of routing). LUT count moved
35,074 -> 35,226 (+152 for the ID detection) and the routed Fmax reads
~24.3 MHz on this run (within the flow's run-to-run routing variance band;
the removed path was previously co-critical at ~38.7 ns). The next attack
point was the CSR `op_result`/`mepc` capture datapath.

### Pipelined mepc capture (Aug 2026)

The trap PC was captured combinationally into `mepc` in the same idle cycle
the trap was detected (`mepc <= i_csr_unit_pc`), putting the whole trap-entry
decode -> `i_csr_unit_pc` mux -> mepc DI tree on the FF-to-FF path. The
capture is now split into two registered stages in `riscv_core_csr_unit.sv`:

- In `idle`, every trap-entry branch captures `trap_pc_reg <= i_csr_unit_pc`
  (a plain 64-bit register) instead of writing mepc directly.
- In `setting_up` (the one-cycle state that follows), `mepc <= trap_pc_reg`
  commits the PC. The pipeline is flushed during `setting_up` and nothing
  reads mepc until the handler's `mret` / `csrr mepc`, many cycles later, so
  the one-cycle delay is invisible. The CSR-write path (`csrw mepc` in idle)
  is unchanged and still writes mepc directly.

Verified: full 22-case SoC sweep + hazard-unit test pass. Result: the mepc
capture chain is **gone from the critical path** — the new worst path
(34.0 ns = 29.4 MHz routed) starts at `instr_wb -> CSR op_result/interrupt-
enable decode` but ends at the icache-miss stall-release handshake
(`jump_id_ex -> DDR stub o_icache_rd_done -> csr_addr_id_ex` CE), not the
mepc DI tree. LUT count moved 35,226 -> 33,558 (-1,668; the mepc DI mux tree
collapsed), +64 FFs for `trap_pc_reg`, and the routed Fmax reads **~29.4 MHz**
(up from 27.7 MHz routed / 36.2 ns). The remaining path is dominated by theCSR `op_result` decode into the stall-release logic.

### Placement-seed sweep (Aug 2026)

`synth/seed_sweep.sh` re-runs nextpnr P&R on the fixed synthesized netlist
with several `--seed` values to measure the placement/routing variance
(the routing term dominates the critical path — ~76% of the path is routing).

**First sweep (old netlist, pre-CSR-stall retiming):**

| seed | routed Fmax |
|------|-------------|
| default | **29.41 MHz** |
| 0  | 28.89 MHz |
| 2  | 28.57 MHz |
| 3  | 29.33 MHz |
| 5  | 29.15 MHz |
| 11 | 29.31 MHz |

**Second sweep (post-CSR-stall netlist, best seeds):**

| seed | routed Fmax |
|------|-------------|
| 7  | **35.87 MHz** |
| 13 | 33.87 MHz |
| 17 | 35.46 MHz |
| 19 | 35.06 MHz |

Seed 7 is the best: **35.87 MHz** routed (the critical path shifted to the
NPU systolic array's 64-bit MAC accumulator carry chain, no longer the
hazard-stall→CE path). `run_synth.sh` now pins `--seed 7` so the canonical
flow reproduces the best result. All seeds P&R to completion and write a
full `ecp5_seed_<n>.config`.

### CSR read-decode pre-retiming (Aug 2026)

The remaining critical path head was the **WB-stage CSR read-data mux**:
`instr_wb[31:20]` (12 address bits) drove a ~29-entry case decode tree through
the mip/mie/sie/sip data bits into `op_result -> result_wb` (~12 ns of the
34 ns path). The safe half to move is the *select* — the CSR address is known
in MEM, while the *data* must stay in WB (CSR writes land in WB; pre-reading
the data in MEM would create a WAR hazard). In `riscv_core_top.sv`:

- A MEM-stage decoder turns `instr_mem[31:20]` into a **29-bit one-hot select**
  (`csr_sel_mem`), registered through the mem_wb pipe (same en/clr as the
  instruction pipe) into `csr_sel_wb`.
- `riscv_core_csr_unit.sv` now takes `i_csr_unit_csr_sel` and the read mux is
  a **flat OR-of-ANDs** over the registered one-hot select × registered CSR
  values instead of a 12-bit address decode tree in the WB stage.

Verified: full 22-case SoC sweep + hazard-unit test pass. Result: the CSR
decode chain is **off the critical path** — the new worst path (31.6 ns =
**31.66 MHz** routed, up from 29.41) starts at `alu_result_ex_mem` -> dcache
`dcache_rd_addr` -> VALID_MEM address decode -> DDR -> `csr_wstrb` -> NPU
`a_base` CE. LUT count moved 33,558 -> 34,102 (+544 for the decode/mux),
+24 FFs for the pipe stage. The remaining path is again routing-dominated
(~4-5 ns logic + ~26 ns routing), so the next moves are either more retiming
of the dcache address->VALID_MEM decode or a wider, lower-density placement.

### Registered MMIO-bridge AXI issue (Aug 2026)

The post-CSR-decode critical path ended at the NPU CSR `a_base` clock-enable:
`alu_result_ex_mem` (store address) -> dcache FSM (VALID_MEM/tag decode,
byte-strobe decoder, `o_mmio_write_valid`) -> **bridge IDLE presenting the AXI
write combinationally from the raw MMIO inputs** -> NPU CSR accept -> `a_base`
CE, all in one cycle across three physically distant modules (~26 ns of
routing). The fix in `c930_mmio_bridge.sv`: IDLE no longer presents the AXI
request at all -- it captures the fields (`awaddr_r`/`wdata_r`/`wstrb_r`, which
it already latched) and advances to `W_AW_W`/`R_AR`, which issue the channels
from the REGISTERED state and captured fields one cycle later. The dcache
holds its request as a level until done and the CSR slave pairs AW/W, so the
handshake is preserved (single accept, no deadlock); MMIO transactions cost
one extra cycle, invisible to software (the C driver polls STATUS).

Verified: full 22-case SoC sweep + hazard-unit test pass. Result: the `a_base`
CE chain is **gone from the critical path** -- the new worst path (31.4 ns =
**31.9 MHz** routed, up from 31.66) starts at `csr_sel_mem_wb` (the registered
one-hot CSR select) -> CSR `mstatus_mie`/`op_result` merge -> ALU carry chain
-> DDR `o_icache_rd_done` -> `rf_rd2_id_ex` CE (the icache-miss stall-release
handshake). LUT count moved 34,102 -> 34,012 (-90; the combinational IDLE
presentation collapsed), and the path is again routing-dominated (8.1 ns logic
+ 23.2 ns routing).

### ID-based CSR-read stall (Aug 2026)

The post-bridge worst path still threaded the **WB-stage CSR read-data mux**:
`csr_sel_mem_wb` (the registered one-hot select) -> CSR `mstatus_mie`/
`op_result` merge -> WB->EX forward -> ALU carry chain -> icache stall-release
-> `rf_rd2_id_ex` CE. The retiming removes the combinational CSR read data
from the data path entirely and delivers CSR reads through the register file:

- **`riscv_core_hazard_unit.sv`** -- the EX-based CSR stall + operand-hold
  machinery (`csr_hold_a/b`, `pcsrc_gate`) is replaced by an **ID-based
  CSR-read stall** mirroring the load-use stall: a dependent in ID whose
  source matches a CSR-read producer (`resultsrc == 2'b11`) in EX, MEM, or WB
  is held in ID until the producer's regfile write commits at the WB negedge.
  The producer is bubbled out of EX (`flush_ex` CSR term) so it can never
  re-execute, and a one-shot **`csr_mem_hold` drain flop** freezes the EX->MEM
  pipe for exactly the producer's first MEM cycle (the load-use stall gets that
  freeze from `dcache_stall`; a CSR read has no dcache service). The WB->EX
  forward now excludes `resultsrc == 2'b11` entirely.
- **`riscv_core_top.sv`** -- `wb_fwd_data` (the WB->EX forward source) carries
  only the REGISTERED mem_wb pipes (`read_data` / `pc_plus_offset` /
  `alu_result`); the combinational `csr_rdata_wb` is intentionally absent, so
  the `csr_sel_mem_wb -> read mux -> result_wb -> src mux -> ALU` chain is off
  the FF-to-FF path. The csr_hold registers and mux overrides are deleted.

This exposed a latent bug in the previous rewrite: the hazard-unit
instantiation had silently dropped the `i_hazard_unit_resultsrc_mem`
connection (an edit accident), leaving `load_in_mem` dead and the MEM->EX
forward firing for load/AMO producers -- the dcache_stress AMO got the previous
AMO's *address* forwarded as its base and faulted (mcause=7 trap loop).
Restored the connection and verified the trap tests (which exercise the CSR
read stall through the handler's `csrrs mcause`/`csrrs mepc` chains) pass.

Verified: full 22-case SoC sweep + hazard-unit test (now cycle-accurate with
the drain pulse) pass. Result: the CSR read-decode chain is **gone from the
critical path** -- the new worst path (28.9 ns = **34.6 MHz** routed, up from
31.9) starts at `instruction_ex_mem` -> regwrite pipe -> branch-unit srcB ->
ALU -> CCU2C carry -> hazard-unit stall detection (`csr_mem_hold`/stall_ex) ->
`csr_addr_id_ex` CE. LUT count moved 34,012 -> 33,767 (-245; the csr_hold
machinery collapsed), FFs 10,707 -> 10,577 (-130), 0 latches, 16 DP16KD /
416 DPR16X4 / 21 DSPs unchanged. The remaining path is againrouting-dominated (6.9 ns logic + 22.1 ns routing), and the Fmax band across
the retiming series is now 24.3 -> 27.7 -> 29.4 -> 31.7 -> 31.9 -> **34.6 MHz**.

### Registered stall-detection retime: attempted and REVERTED (Aug 2026)

The post-CSR-stall worst path ended at the id_ex pipe clock-enables
(`instruction_ex_mem` -> hazard-unit stall detection -> `csr_addr_id_ex` CE).
Registering the CSR/load-use stall detection (`dep_stall_reg`) was tried so the
comparison chain would end at the flop D instead of the ~fifteen 64-bit id_ex
CEs. The A/B against the combinational baseline is unambiguous: **the
registered version breaks the SoC sweep** (amo_stress fails at 0x204: the
+0x2 store and amo_xor never reach the dcache; w[1] stays 0x1112 in DDR),
while the identical binary with the combinational stall passes all 22 cases.

The mechanism (traced cycle-by-cycle in the sim): the icache's period-2
hit-stall loop freezes the pipeline every other cycle, and a plain store whose
MEM phase spans that freeze stays in MEM past the dcache's service completion
-- the level-based request re-dispatches (a double write-through; benign for an
idempotent store). The one-cycle registered lag on stall_ex shifts the whole
instruction stream's phase against the period-2 loop, landing the downstream
AMO/store sequence in a corrupting configuration (the store re-dispatch delays
the pipeline and later ops are lost). The stall protocol -- combinational
detection, deferred flush, cycle-accurate release against the dcache's
LOAD_DONE -- is a correctness invariant of this design; the id_ex CE cone is
best attacked by placement (routing is 76% of the path), not by shifting the
stall timing.

Net: hazard unit reverted to the combinational baseline (34.6 MHz stands),
and the invariant is locked in as **Case 10 of tb_hazard_csrflush.sv**: a LOAD
producer in EX with a dependent in ID while `dcache_stall` is still asserted
must keep `stall_ex` high (id_ex frozen -- `flush_ex` is deferred by the
dcache_stall guard, so a clear stall_ex would capture the dependent into EX).




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
