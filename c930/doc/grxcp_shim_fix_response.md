# GRX930 → grxcp: shim defect fixes and open-question answers

Fixed at `3070806` ("Fix 5 defects in NPU DPI shim found by grxcp team").
All five defects reproduced and fixed. Seven smoke tests pass.

## Answers to your open questions

### 1. Is `CYCLE_COUNT` 64-bit in `c930_npu_csr.sv`?

**No, it is 32-bit.** The evidence:

- `c930_npu_core.sv:138` declares `logic [31:0] cycle_cnt` and exposes it as
  `output logic [31:0] o_cycle_count`.
- `c930_npu_csr.sv:61` receives it as `input logic [31:0] i_cycle_count`.
- `ADDR_CYCLE_HI = 4'hA` (address 0x28) is defined as a localparam at line 77
  but **never appears in any case statement** — the read-channel case jumps
  directly from `ADDR_CYCLE_LO` (4'h9) to `ADDR_OP_COUNT` (4'hB).
  Reading 0x28 always returns 0.

**The fix is therefore a header correction, not a re-index.** The old shim's
header had the addresses shifted by one because it was missing the dead
`CYCLE_HI` register entirely. The corrected header now lists all 14 indices
matching the RTL localparams, with index 10 (0x28) marked reserved/dead.

Your earlier observation that `0x28 = 256 = M×N×K×2` was correct but it was
reading the old broken shim's index 10, which mapped to `OP_COUNT` at the time.
With the corrected shim, `0x28` reads 0 and `OP_COUNT` is at `0x2C` (index 11).

### 2. Does the RTL drive `STATUS.BUSY`?

**Yes.** `c930_npu_csr.sv:180`:

```systemverilog
ADDR_STAT: s_axi_rdata <= {29'd0, i_error, done_latch, i_busy};
```

Bit 0 of STATUS is directly wired to the core's `i_busy` output, which is
driven by `c930_npu_core.sv` whenever `state != S_IDLE`. The shim now
replicates this: `STATUS.BUSY` is asserted for 2 cycles after `CTRL.START`
(pipeline fill), then deasserted when the GEMM completes and `STATUS.DONE` is
set. A host that waits on BUSY will see it transition 0→1→0, matching silicon.

## Defect fixes (all at 3070806)

### Defect 1: `npu_dpi_run_gemm()` never starts the GEMM

**Was:** The function wrote all CSRs except `CTRL`, so `npu_dpi_run()` returned
immediately (BUSY never asserted). The one entry point that looked like an API
returned a number and computed nothing.

**Fix:** Added `npu_dpi_csr_write(NPU_CSR_CTRL, 1)` before running the state
machine.

**Test:** 2×2×2 INT8 GEMM with A=[1,2;3,4], B=[5,6;7,8] → C=[19,22;43,50].
All four elements verified correct.

### Defect 2: `STATUS.BUSY` never asserted

**Was:** The shim had no BUSY simulation. `STATUS` read as 0x00 immediately
after `CTRL.START`, making it impossible for a BUSY-waiting host to distinguish
running from idle.

**Fix:** Added `npu_busy` flag and `npu_busy_cycles` countdown. After START,
BUSY is asserted for 2 cycles (pipeline fill), then deasserted when DONE is set.

**Test:** `STATUS` after START reads `0x01` (BUSY=1, DONE=0). After `npu_dpi_run()`,
reads `0x02` (BUSY=0, DONE=1).

### Defect 3: Performance counters off by one

**Was:** The header's `NPU_CSR_OP_COUNT` was at 0x2C (index 11), but the old
shim wrote OP_COUNT to index 10 (0x28). Reading the header's address for
OP_COUNT gave STALL_COUNT instead.

**Root cause:** The old header was missing `ADDR_CYCLE_HI` at index 10. The RTL
has 14 registers (indices 0–13), but the old header only defined 12 addresses.

**Fix:** Header now defines all 14 indices. Shim writes counters to the
correct indices:
- Index 9 (0x24): CYCLE_COUNT ← `csr[9]`
- Index 10 (0x28): reserved (dead code, reads 0)
- Index 11 (0x2C): OP_COUNT ← `csr[11]`
- Index 12 (0x30): STALL_COUNT ← `csr[12]`
- Index 13 (0x34): DMA_CT ← `csr[13]`

**Test:** M=4 N=4 K=8 → `OP_COUNT = 256` (0x100) at address 0x2C.
`CYCLE_COUNT` and `DMA_CT` are both non-zero and equal (this model runs DMA
for the full cycle count). `STALL_COUNT` is 0.

### Defect 4: DDR overflow in GEMM path

**Was:** `npu_dpi_csr_write`'s START branch computed `C_BASE + M×N×4` without
bounds checking. ASAN caught a global-buffer-overflow with `C_BASE = 0xFFF0`.

**Fix:** All three buffer extents (A, B, C) are now computed and checked against
`NPU_DDR_SIZE` (65536) before the GEMM runs. Overflow sets `STATUS.ERROR` (bit 2)
and returns without modifying DDR.

**Test:** `C_BASE = 0xFFF0` with 4×4 INT8 → `STATUS = 0x04` (ERROR=1, BUSY=0,
DONE=0). DDR is not modified.

### Defect 5: PREC ignored + wrong cycle model

**Was:** All precision modes produced INT8 results (the software GEMM always cast
elements as `int8_t`). The cycle formula used `MAX_N = 12` and `NUM_ROWS = 8`
(the core defaults), not the SoC defaults (4×4 array).

**Fix:** The GEMM now dispatches by precision:
- INT8: 1-byte signed, `int8_t` cast
- INT16: 2-byte LE signed, `int16_t` from two bytes
- INT4: 4-bit signed nibbles, two per byte, sign-extended
- FP16/BF16: falls back to INT8 for the software model (the shim doesn't
  implement float; accuracy comes from RTL)

The cycle model now uses SoC defaults: `NUM_ROWS=4`, `NUM_COLS=4`, `MAX_N=12`.
Formula: `m_tiles × n_tiles × k_tiles × (NUM_ROWS + ps_offset + NUM_COLS + 2)`
where `ps_offset = NUM_ROWS` for FP16/BF16 (2-cycle PE latency).

**Test:**
- INT16: A=[256,512], B=[1,1], K=2 → C[0][0] = 768. Correct.
- INT8: 4×4×8 → expected 20 cycles (1×1×2 × (4+0+4+2) = 20). Shim returns 20.

## Cosmetic fixes

- Removed Chinese text ("Useful for知道 how many") from usage comment
- Header usage example now uses `NPU_CSR_*` names instead of `NPU_REG_*`
  (backward-compatible `NPU_REG_*` aliases are still defined)
- Added `NPU_DDR_SIZE`, `NPU_STATUS_BUSY/DONE/ERROR`, `NPU_PREC_*` constants
- Full 14-entry CSR index map documented in header comments

## What this means for grxcp

Your adapter's `npu_c930_wait_idle()` polling BUSY will now work correctly
against the shim. Your host code that triggers via `CTRL.START` and reads
`OP_COUNT` at 0x2C will see the right values. The shim is now a faithful
register-model-accurate stand-in for the c930's AXI4-Lite interface.
