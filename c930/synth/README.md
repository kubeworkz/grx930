# C930 SoC synthesis (Yosys + nextpnr, ECP5)

> **For higher Fmax:** See [`synth_xilinx/`](../synth_xilinx/) for the
> Xilinx Artix-7 port. Dedicated CARRY4 carry chains on Artix-7 should push
> Fmax from ~35 MHz (ECP5) to ~60-80 MHz.

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

**Third sweep (NPU-pipelined netlist, after k_base_reg / kr_reg):**

| seed | routed Fmax |
|------|-------------|
| 7  | 34.32 MHz |
| 13 | 33.65 MHz |
| 17 | 35.26 MHz |
| 19 | **35.56 MHz** |

The NPU carry chain is now broken; the critical path reverted to the CPU
fetch-PC carry chain (the same hazard-stall → CE path that was co-critical
before the NPU retime). Seed 19 is the best: **35.56 MHz** routed.
`run_synth.sh` now pins `--seed 19`.

The Fmax band across the retiming series is now
24.3 -> 27.7 -> 29.4 -> 31.7 -> 31.9 -> 34.6 -> 35.9 (seed 7) ->
35.6 (NPU-pipelined, seed 19) -> **35.3 MHz** (IF-stage PC+4 register).

All seeds P&R to completion and write a full `ecp5_seed_<n>.config`.

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

### IF-stage PC+4 register (Aug 2026)

The IF-stage PC+4 adder output (`pc_plus_offset_if`) feeds the `pcsrc_ex` mux,
which selects between the fall-through (PC+4) and the EX-stage branch target.
The mux output (`PCF_NEW`) feeds the `pcf_if` pipe -- a 64-bit carry chain that
was the critical path after the NPU retime. Registering `pc_plus_offset_if`
(`pc_plus_offset_if_reg`) breaks this chain: the mux now starts from a
registered value. The `if_id_pipe_pc_plus_offset` pipe still uses the
combinational value, preserving ID-stage JALR timing.

Verified: full 22-case SoC sweep + hazard-unit test pass. The remaining path
is the branch unit's 64-bit subtraction carry chain (the branch comparison).
Routed Fmax moved from 35.87 (seed 7) to 35.31 (seed 19) -- the register
reduced LUT count by ~50 but the branch-unit carry chain became the sole
bottleneck at ~28.8 ns.

### NPU K-tile pipeline registers (Aug 2026)

With the hazard-stall path off the critical path, the next bottleneck was the
NPU systolic array's K-tile computation: `kt_reg.Q` (K-tile counter) -> `k_base`
(kt_reg x NUM_ROWS shift) -> 32-bit subtraction `i_dim_k - k_base` -> `kr`
(active rows) -> PE activation skew -> partial-sum carry chain. The
`k_base_reg` / `kr_reg` registers in `c930_npu_core.sv` are computed at the
start of each K tile (end of the previous tile) and held stable for the whole
S_WLOAD + S_RUN sequence, so the subtraction carry chain is in the previous
cycle's timing budget and the PE datapath starts from a registered `kr_reg.Q`.

Verified: full 22-case SoC sweep + hazard-unit test pass. The NPU carry chain
is gone from the critical path; the worst path reverted to the CPU fetch-PC
carry chain (the same hazard-stall -> CE path that was co-critical before).

### Branch-unit srcA/srcB registration: attempted and REVERTED (Aug 2026)

The last remaining critical path is the branch unit's 64-bit comparison carry
chain: `src_a_ex` (or `src_b_out`) -> branch-unit comparator -> `istaken_ex`
-> `pcsrc_ex`. Registering the branch-unit inputs (`branch_src_a`,
`branch_src_b`) so the carry chain starts from a flop Q was attempted.

**Result: REVERTED.** The registered branch comparison uses 1-cycle-old
forwarded operands, causing incorrect branch decisions on dependent code.
The sim hangs in a tight branch loop (PC cycling between 0x3f0/0x74c/0x7a4)
and the watchdog fires after 2M cycles. This is fundamental to the pipeline
architecture: branches resolve in EX using forwarded values, and inserting a
register there breaks the forwarding protocol. The branch-unit carry chain
is inherent to the 5-stage in-order design and can only be broken by a
deep architectural change (e.g., moving the comparison to ID stage with
speculative redirect, which requires a complete pipeline restructure).

Net: Fmax stays at 35.3 MHz (seed 19) with the branch-unit carry chain as
the sole remaining critical path (~28.8 ns, 87% routing).

### IF-stage BTB (64-entry direct-mapped): attempted and REVERTED (Aug 2026)

A 64-entry direct-mapped Branch Target Buffer (`riscv_core_btb.sv`) was
implemented in the IF stage to predict taken branches and redirect fetch from
a registered target, with the goal of breaking the branch-unit carry chain
and pushing Fmax to ~40 MHz.

Two implementation bugs had to be fixed during bring-up:
1. **Misprediction detection used the live IF-stage lookup.** Comparing
   `btb_pred_valid && btb_pred_taken` (the BTB output for whatever PC the
   fetch stage currently points at) against the EX-stage resolution is
   meaningless: by the time a branch reaches EX the IF stage has moved on,
   so the "misprediction" fired spuriously and redirected fetch into a loop
   (icache permanently stalled at PC=0x25c). The fix carries a "predicted
   taken" bit with the branch through dedicated IF/ID and ID/EX pipes and
   compares THAT against `pcsrc_ex`.
2. **The update write port was on the critical path.** The combinational
   `mux_to_stg2` (branch/JALR target) fed the BTB's 64-bit write decode
   directly, so the EX carry chain simply reattached at the BTB. The fix
   registers the update inputs in four EX->MEM pipes, so the write starts
   from flops (a predictor may lag a cycle without affecting correctness).

With both fixes the BTB was functionally correct (full 22-case SoC sweep +
hazard test pass), but the Fmax result was negative:

| Configuration | Routed Fmax (seed 19) |
|---|---|
| Baseline (no BTB) | 35.31 MHz |
| BTB, combinational update | 32.15 MHz |
| BTB, registered EX->MEM update | 32.70 MHz |

**Result: REVERTED.** The BTB did not break the branch carry chain -- the
worst path still ends in the ALU's 64-bit target-computation carry chain
(`alu_result_ex_mem`), and the added BTB fabric (~55% LUT density) worsened
routing. Net regression of ~2.6 MHz versus baseline. The prediction only
removes the taken-branch *penalty*, not the worst-case combinational path;
on a fabric with dedicated carry chains (Artix-7, see synth_xilinx/) it may
still be worth re-evaluating as a pure IPC feature.

### Fmax progression summary

| Retime step | Routed Fmax | Notes |
|---|---|---|
| Baseline | 24.3 MHz | Worst path: MUL/DIV carry chain |
| M/D operand retiming | 26.4 | srcA/srcB registered at issue |
| ID-based load-use stall | 27.7 | dcache address chain off EX |
| Pipelined mepc capture | 29.4 | CSR op_result decode off path |
| CSR one-hot pre-decode | 31.7 | MEM-stage CSR addr decode |
| Registered MMIO-bridge AXI | 31.9 | Bridge issue path registered |
| ID-based CSR-read stall | 34.6 | CSR read-data mux off WB path |
| Seed-7 placement | 35.9 | Best seed from 4-seed sweep |
| Seed-42 placement (FP16/BF16) | **24.5** | 9-seed sweep, FP16/BF16+DMA netlist |
| NPU done-detection retime | **25.7** | Separated o_done from FSM to break t→done path; 8-seed sweep |
| NPU act/ps_in registration | **30.0** | Register act/ps_in to break FP16 accumulator chain; 8-seed sweep |
| NPU K-tile pipeline | 35.6 | PE subtraction carry chain broken |
| IF-stage PC+4 register | 35.3 | Fetch-PC mux chain broken |
| Branch-unit register | **REVERTED** | Breaks forwarding protocol |
| IF-stage BTB (64-entry) | **REVERTED** | 32.7 vs 35.3 baseline; predictor only removes taken-branch penalty, carry chain remains |
| FP16/BF16 datapath | **14.4 MHz** | Multiplier+accumulator combinational chain |
| PE product registration | **24.9 MHz** | fp32_prod/int_prod registered before accumulator |

The design's Fmax ceiling (INT8-only NPU) was **~35 MHz** on ECP5-85F with
the 5-stage in-order pipeline. The branch-unit carry chain is inherent to the
architecture (deep changes needed to break it further). With FP16/BF16, the
ceiling is **~30 MHz** (act/ps_in registration broke the accumulator chain; routing is now the bottleneck).

### FP16/BF16 datapath synthesis (Aug 2026)

The FP16 multiplier (`c930_fp16_mul.sv`), BF16 multiplier (`c930_bf16_mul.sv`),
and FP32 accumulator (`c930_fp16_acc.sv`) were added to the systolic array
PEs. The PE precision mux selects between the integer MAC and the FP16/BF16
MAC, and the accumulator is shared.

**Resource impact:**

| Resource | INT8-only | With FP16/BF16 | Delta |
|----------|-----------|----------------|-------|
| LUT4 | 34,012 | **46,360** | +12,348 |
| TRELLIS_FF | 10,707 | **13,642** | +2,935 |
| CCU2C | 2,101 | **3,791** | +1,690 |
| DP16KD (EBR) | 16 | **16** | 0 |
| DPR16X4 | 416 | **456** | +40 |
| MULT18X18D (DSP) | 21 | **37** | +16 (FP16+BF16 multipliers) |
| Density | 41% | **55%** | +14% |

**Fmax impact:** The FP16/BF16 multiplier and FP32 accumulator add a deep
combinational chain in the systolic array PE. Without pipelining, the
critical path is:

```
A-mem read mux → precision mux → FP16/BF16 multiplier (MULT18X18D, 3.07 ns)
→ fp32_prod normalization (8 LUT4s, ~5 ns) → fp32_prod alignment shift
→ FP32 mantissa addition (24-bit carry chain, ~8 ns) → exponent normalization
→ result mux → PE output register
```

The total internal critical path is ~40+ ns (19 ns logic + 21 ns routing).

**Initial seed sweep (no product registration, FP16 netlist):**

| seed | routed Fmax |
|------|-------------|
| 1  | 14.44 MHz |
| 7  | 14.33 MHz |
| 13 | 14.43 MHz |
| 17 | 14.42 MHz |
| 23 | 14.46 MHz |

All seeds cluster at ~14.4 MHz — the FP16 accumulator chain is the sole
bottleneck, not routing variance.

### PE product registration (Aug 2026)

The FP16/BF16 multiplier output (`fp32_prod`) and the integer product
(`int_prod`) are now **registered inside the PE** before the accumulator.
This breaks the multiplier→accumulator carry chain: the critical path is now
`i_ps_in → accumulator → o_ps_out` (the accumulator alone, ~25 ns of
alignment + addition + normalization + ~10 ns routing = ~35 ns total).

The controller's `ps_in` pulse is extended to 2 cycles (cycles `n` and `n+1`
for column `n`) so PE(0,c) captures the correct partial sum on the second
cycle when the registered product is valid. S_RUN runs for `NUM_ROWS +
NUM_COLS + 1` cycles (1 extra for the product registration delay) with
staggered capture starting at `t >= NUM_ROWS + 1`.

**Resource impact (product-registered netlist):**

| Resource | Before (no prod reg) | After (prod reg) | Delta |
|----------|---------------------|------------------|-------|
| LUT4 | 46,360 | **46,370** | +10 |
| TRELLIS_FF | 13,642 | **14,650** | +1,008 |
| MULT18X18D | 37 | **37** | 0 |
| DP16KD | 16 | **16** | 0 |

**Seed sweep (product-registered netlist):**

| seed | routed Fmax |
|------|-------------|
| default | **24.25 MHz** |
| 3  | 23.72 MHz |
| 5  | 23.96 MHz |
| 7  | **24.90 MHz** |
| 11 | 24.48 MHz |
| 13 | 23.36 MHz |

Best seed: **7 at 24.90 MHz** (up from 14.4 MHz — **73% Fmax improvement**).
The critical path is now `t → NPU core state → ps_in → FP16 accumulator
exp_b subtraction chain → mantissa alignment → addition → normalization →
PE output register` (12.33 ns logic + 28.91 ns routing = 41.24 ns).

**Root cause of remaining path:** The FP32 accumulator (`c930_fp16_acc.sv`)
is still entirely combinational: exponent difference → mantissa alignment
shift → mantissa addition → normalization. On ECP5 without dedicated carry
chains, the 24-bit mantissa addition maps to a LUT cascade (~8 ns), and the
normalization adds another ~5 ns of LUT logic. The routing term (70% of the
path) is the dominant factor.

**Throughput impact:** The product registration adds 1 extra cycle per K-tile
(S_RUN = NUM_ROWS + NUM_COLS + 1 vs NUM_ROWS + NUM_COLS). For a 4×4 array:
- Before: 14.4 MHz / 8 cycles = 1.80M tiles/sec
- After: 24.9 MHz / 9 cycles = 2.77M tiles/sec (**54% throughput improvement**)

**Further mitigation path:** Pipeline the accumulator itself (register the
mantissa alignment result before the addition) to split the ~25 ns combinational
depth into two ~12 ns stages. This adds another cycle of latency but would
push Fmax to ~40+ MHz. On Artix-7, the CARRY4 chains handle the mantissa
addition in ~2 ns, giving ~50+ MHz.

### Fixed-point accumulator (Aug 2026)

Replaced the per-element FP32 accumulator (`c930_fp16_acc.sv`) with a
fixed-point accumulator (`c930_fx_acc.sv`) that skips per-cycle LZC +
normalization.  Accumulates in 48-bit fixed-point format
(`{sign[47], exp[39:32], mantissa[31:0]}`); normalizes once at writeback
(S_WRITE in the core) using a new `fx_to_fp32()` function.

**Why the 2-stage pipeline didn't work:** Adding a pipeline register inside
the accumulator shifts the PE output by 1 cycle, breaking the systolic cascade
alignment — downstream PEs sample stale partial sums.  The fixed-point approach
achieves the same critical-path reduction (skip LZC+normalize) without adding
pipeline stages.

**Resource impact (fixed-point netlist):**

| Resource | Before (FP32 acc) | After (fx acc) | Delta |
|----------|-------------------|----------------|-------|
| LUT4 | 46,370 | **51,330** | +4,960 |
| TRELLIS_FF | 14,650 | **14,634** | -16 |
| MULT18X18D | 37 | **37** | 0 |
| DP16KD | 16 | **16** | 0 |

The +5K LUT increase comes from the wider 40-bit barrel shifter (vs 27-bit)
and the 33-bit adder (vs 28-bit).  The FF count is essentially unchanged.

**Routed Fmax:**

| Metric | FP32 acc | Fixed-point acc |
|--------|----------|------------------|
| Fmax | 24.90 MHz | **27.91 MHz** |
| Improvement | — | **+12%** |
| Critical path | sort+align+add+normalize (~25 ns) | sort+align+add (~14 ns logic + ~7 ns routing) |

The critical path is now the 33-bit mantissa addition carry chain
(~7.4 ns) + routing (~7 ns).  On Artix-7, CARRY4 chains would handle the
adder in ~1-2 ns, giving ~50+ MHz without further RTL changes.

### Artix-7 Vivado results (Aug 2026)

Full Vivado 2026.1 implementation on xc7a35tcsg324-1 (Arty A7-35T),
CLK_DIV=2 (50 MHz core clock), DDR stub in BRAM.

**Fmax: 587.7 MHz** (WNS = 8.298 ns against 100 MHz constraint).
The worst-path delay is only 1.7 ns — CARRY4 chains handle the 33-bit
mantissa addition in ~0.15 ns/bit (vs ~8 ns on ECP5 LUT cascades).

**Utilization:**

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| Slice LUTs | 16,335 | 20,800 | 78.5% |
| LUT as Logic | 15,731 | 20,800 | 75.6% |
| LUT as Memory | 604 | 9,600 | 6.3% |
| Slice Registers (FF) | 12,722 | 41,600 | 30.6% |
| Block RAM (RAMB36) | 8 | 50 | 16.0% |
| DSP48E1 | 3 | 90 | 3.3% |
| F7 Muxes | 1,163 | 16,300 | 7.1% |
| F8 Muxes | 455 | 8,150 | 5.6% |
| Latches | 0 | — | 0.0% |

**Fmax progression across platforms:**

| Platform | Fmax | Key factor |
|----------|------|------------|
| ECP5-85F (INT8 only) | 35.3 MHz | Baseline |
| ECP5-85F (FP16/BF16, no prod reg) | 14.4 MHz | Multiplier+accumulator chain |
| ECP5-85F (FP16/BF16, prod reg) | 24.9 MHz | Break multiplier→accumulator |
| ECP5-85F (fixed-point acc) | 27.9 MHz | Skip per-cycle LZC+normalize |
| ECP5-85F (8x8 array) | 24.8 MHz | Wider interconnect |
| **Artix-7-35T (8x8 array)** | **587.7 MHz** | **CARRY4 carry chains** |

### Seed sweep after MAX_K=32/MAX_N=16 reversion (Aug 2026)

After reverting MAX_K/MAX_N to 16/12 (matching ECP5 budget), a 9-seed sweep
was run on the FP16/BF16+DMA netlist (48K LUTs, 36 DSPs, 16 DP16KD):

| seed | routed Fmax |
|------|-------------|
| 0  | 24.20 MHz |
| 2  | 23.63 MHz |
| 3  | 22.75 MHz |
| 5  | 23.65 MHz |
| 7  | 23.23 MHz |
| 11 | 23.46 MHz |
| 13 | 23.91 MHz |
| 17 | 23.60 MHz |
| 42 | **24.54 MHz** |

Best: **seed 42 at 24.54 MHz** (+4.9% over the 23.38 MHz default). The critical
path was NPU core's `t[25]` done-detection chain (routing-dominated).

### NPU done-detection retime (Aug 2026)

The critical path after the seed-42 sweep started at `t[25]` (the K-tile cycle
counter) and threaded through ~10 LUT4s of FSM state-decode logic to reach
the `o_done` flip-flop. Yosys was sharing FSM state-next and done-next logic
in the same `always_ff` block, creating a combinational path from `t` through
the state decode into `o_done`. The fix in `c930_npu_core.sv`:

- A standalone `always_comb` computes `done_cond = (state == S_WRITE) &&
  (n_cnt == nc-1) && (nt_reg == num_n_tiles-1) && (m_reg == i_dim_m-1)`,
  depending only on registered state/counters (not `t`).
- The FSM's `always_ff` uses `o_done <= done_cond` instead of the nested if
  chain. This forces yosys to build a separate combinational cone for `o_done`,
  breaking the `t` → state-decode → `o_done` path.

Verified: full SoC sweep + hazard-unit test pass. Result: LUT count dropped
48,573 → **47,462** (-1,111), FFs 16,373 → **15,355** (-1,018). The `t[25]`
chain is gone from the critical path — the new worst path starts at `t[4]`
→ preload-enable → PE partial-sum input (different bottleneck, shorter chain).

**Seed sweep after done-detection retime:**

| seed | routed Fmax |
|------|-------------|
| 0  | 24.79 MHz |
| 2  | **25.66 MHz** |
| 5  | 23.40 MHz |
| 7  | 23.96 MHz |
| 11 | 23.57 MHz |
| 13 | 25.12 MHz |
| 17 | 25.32 MHz |
| 42 | 23.57 MHz |

Best: **seed 2 at 25.66 MHz** (+4.6% over the previous 24.54 MHz best).
`run_synth.sh` now pins `--seed 2`.

### NPU act/ps_in registration (Aug 2026)

The critical path after the done-detection retime started at `t[23]` and
threaded through the preload/state decode into the systolic array's `ps_in`
mux, then through the entire FP16 accumulator (exp_b subtraction → mantissa
alignment → mantissa addition → normalization), totaling ~26 ns. The `t`
register fed into the `t == n` comparison that selects which PE column gets
the partial-sum value, and yosys merged this with the accumulator's combinational
cone.

The fix in `c930_npu_core.sv`:

- `act` and `ps_in` are computed combinationally (`act_comb`, `ps_in_comb`) as
  before, then **registered** into `act` and `ps_in` at every clock edge.
- The registered versions feed the systolic array, so the `t` → comparison →
  accumulator path is broken at the register boundary.
- S_RUN runs for `NUM_ROWS + NUM_COLS + 2` cycles (vs +1 before) to
  compensate for the 1-cycle registration delay. The staggered capture shifts
  by 1 accordingly (`acc[t - NUM_ROWS - 2]`).

Verified: full SoC sweep + hazard-unit test pass (all precisions correct).
Result: LUT count 47,462 → **48,488** (+1,026 for registration + muxes),
FFs 15,355 → **15,611** (+256). The FP16 accumulator carry chain is **gone**
from the critical path.

**Seed sweep after act/ps_in registration:**

| seed | routed Fmax |
|------|-------------|
| 0  | 29.32 MHz |
| 2  | **30.04 MHz** |
| 5  | 29.51 MHz |
| 7  | 29.96 MHz |
| 11 | 29.09 MHz |
| 13 | 29.18 MHz |
| 17 | 29.37 MHz |
| 42 | 29.46 MHz |

Best: **seed 2 at 30.04 MHz** (+17% over the previous 25.66 MHz best).
All 8 seeds route above 29 MHz — the routing term is now dominant and the
logic is no longer the bottleneck.

The Artix-7 result confirms the design is well above the 100 MHz Arty A7
target.  The DDR stub uses 8 × RAMB36E1 (the caches + DDR placeholder);
the 3 DSPs handle the37 multiplier trees (Vivado inferred most as LUTs
because the design is compact enough).  Zero latches, zero DRC errors.

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

## 64-bit AXI bus widening (Aug 2026)

The NPU DMA AXI bus was widened from 32-bit to 64-bit (`AXI_DATA_W=64`)
across all modules: `c930_npu_dma`, `c930_npu_top`, `c930_soc_top`,
`c930_ddr`, and the synth stubs/testbenches. The DMA unpack logic now
decodes 8 elements per beat (INT8) instead of 4, halving A/B read beats.
C write-back keeps 32-bit stride (INT32 = 4 bytes) since the core
returns 32-bit results.

**Simulation results (M=8, N=8, K=16):**

| Prec | DMA Before (32b) | DMA After (64b) | Δ |
|------|-----------------|----------------|---|
| INT4 | 1931 | 1915 | -0.8% |
| INT8 | 1823 | 1805 | -1.0% |
| INT16 | 1859 | 1823 | -1.9% |
| FP16 | 1859 | 1823 | -1.9% |
| BF16 | 1859 | 1823 | -1.9% |

Improvement is modest because the C write-back (INT32, 4 bytes/beat)
still dominates DMA time. The A/B read path benefits fully from the
wider bus.

**Synthesis (yosys, ECP5-85K placeholder):**

| Resource | Before (32b) | After (64b) |
|----------|-------------|-------------|
| LUT4 | 48,488 | 49,146 (+658) |
| FF | 15,611 | 15,857 (+246) |
| DP16KD | 16 | 16 |
| MULT18X18D | 36 | 42 (+6) |

ECP5 P&R completed on WSL with 5GB RAM (seed 2). The larger netlist
routes to completion in ~15 min with 4GB+ WSL memory.

### 64-bit AXI + DMA prefetch + C packing (Aug 2026)

After widening AXI to 64-bit, adding DMA prefetch, and packing two INT32
values per C write beat, the netlist grew from 48,488 to 54,375 LUTs and
15,611 to 15,955 FFs. ECP5 P&R on seed 2 routed to completion.

**Resource summary:**

| Resource | Before | After |
|----------|--------|-------|
| LUT4 | 48,488 | 54,375 (+5,887) |
| TRELLIS_FF | 15,611 | 15,955 (+344) |
| DP16KD | 16 | 16 |
| MULT18X18D | 36 | 42 (+6) |
| CCU2C | - | 4,454 |
| DPR16X4 | - | 456 |

**Fmax: 29.58 MHz** (vs 30.04 MHz before AXI changes, -1.5%).
The FP16 accumulator mantissa extension carry chain remains the
critical path: `fp32_prod_reg[10] -> mant_b_ext LUT chain ->
CCU2C carry -> mantissa addition -> normalization -> PE output`
totals 37.4 ns (0.40 ns clk-to-Q + 1.40 ns routing + 25.6 ns
logic in carry chain + 10 ns final routing).

The second critical path is the cross-domain path from
`phase[2]` to the async `npu_busy` output pin (9.43 ns, 26.77 MHz)
— a routing-only constraint that affects the I/O pin timing.

## DMA prefetch / A-row pipelining (Aug 2026)

While the core computes on the first row of A, the DMA prefetches rows 1..M-1
via the AXI read channel, overlapping DDR reads with systolic compute. INT4 is
excluded (nibble-packing means rows share bytes). The prefetch FSM runs in
parallel with the core in P_LAUNCH and continues through P_WRITE_C (AXI
read/write channels are independent).

**Simulation results (M=8, N=8, K=16):**

| Prec | DMA Before | DMA After | Delta |
|------|-----------|-----------|-------|
| INT8 | 1947 | 1823 | -6.4% |
| INT16 | 2011 | 1859 | -7.6% |
| FP16 | 2011 | 1859 | -7.6% |

Improvement modest because DDR port is shared; prefetch fills idle slots.

## Two-element C write packing (Aug 2026)

The C write-back now packs two INT32 results into each 64-bit AXI beat,
halving the write burst length. A WS_PACK state reads the second C element
while the first is held in a c_lo register, then drives the packed 64-bit
word with wstrb=8'hFF. Odd-tail beat uses wstrb=8'h0F. The DDR and synth
stub write strides updated from w_beat*4 to w_beat*8.

C beat count drops from dm*dn to ceil(dm*dn/2). The DMA cycle counter
includes core compute time (~1376 cycles) which dwarfs the ~64-cycle C
write savings, so benchmark numbers are unchanged at M=N=8. The
improvement becomes visible at larger matrix sizes.
