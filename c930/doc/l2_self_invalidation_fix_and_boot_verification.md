# L2 Self-Invalidation Fix & Verilator Boot Verification

**Date:** September 12, 2026
**Status:** ✅ Fixed and verified — 18/18 GEMM sweep PASS with L2 enabled
**Author:** GRX930 team (Buffy/Codebuff)

---

## Executive Summary

A critical L2 cache bug caused the D-cache to lose its valid bits during normal write-through traffic, preventing the GRX930 SoC from booting. The root cause was a self-invalidation loop: the D-cache reads a line (becoming an L2 sharer), then writes through — the L2 invalidates ALL sharers including the D-cache itself. This was fixed by excluding the writing master from the invalidation mask. With the fix, the GRX930 SoC boots correctly and passes all 18 GEMM test cases with L2 enabled.

---

## 1. The Bug: L2 Self-Invalidation During Write-Through

### 1.1 Symptom

The CPU would boot, execute startup_c, clear BSS, and enter process_command — but the BSS clear loop appeared to never complete. The DDR trace showed:
- Every D-cache write to BSS triggered a cache line read (miss)
- Even writes to the **same cache line** triggered re-reads
- The CPU was stuck reading address 0xAC0 (within BSS) in an infinite loop

With `BYPASS_L2=1`, the BSS clear loop worked correctly and the CPU booted.

### 1.2 Root Cause

The L2 cache's write path (`WR_LOOKUP → WR_INV`) invalidated **all** sharers of a cache line when any master wrote through. The self-invalidation loop:

```
1. D-cache read-miss → reads cache line from DDR via L2
2. L2 caches the line, records D-cache (SOURCE_ID=1) as a sharer
3. D-cache write-through → L2 WR_LOOKUP finds the line (cached from step 2)
4. L2 WR_INV invalidates ALL sharers, including the D-cache itself
5. D-cache valid bit cleared → next write to same line is a miss again
6. Go to step 1
```

This created an infinite loop where every D-cache write-miss filled the cache line, but the L2 immediately invalidated it.

### 1.3 The Fix

**File:** `c930_l2.sv`, line 646

```diff
- wr_inv_mask <= inv_mask_of_sharers(sharers[w][wr_cur_line[OFF_BITS +: SET_BITS]]);
+ wr_inv_mask <= inv_mask_of_sharers(sharers[w][wr_cur_line[OFF_BITS +: SET_BITS]]) & ~inv_port_of_src[wr_id];
```

The fix excludes the writing master's port from the invalidation mask. The writer already knows it's writing the line (it initiated the write-through), so it doesn't need to be invalidated. Other sharers (e.g., I-cache, other cores) still receive the invalidation.

### 1.4 Why This Wasn't Caught Earlier

The previous 18-case GEMM sweep (commit 150ce16) was run with `BYPASS_L2=1` (L2 disabled). The L2 was added later for multi-core coherency, but the write-through self-invalidation bug was never exposed because:
1. The echo firmware's BSS is tiny (4 bytes) — the loop completes before the L2 can interfere
2. The GEMM firmware's A/B/C buffers are preloaded via the TB port, not written by the CPU
3. Only the BSS clear loop (many writes to the same cache lines) triggers the self-invalidation

---

## 2. Additional Fixes in This Session

### 2.1 DDR Verilator Model Address Decode

**File:** `c930_ddr_verilator.sv`

The DDR model's AXI read path used only 9 bits of address (`line_base = {rd_line_q, 5'b0}`), limiting addressable memory to 512 bytes. The firmware's BSS section at 0x6C0 was beyond this limit, causing the DDR to return wrong data.

**Fix:** Widened `rd_line_q` from 4 bits to 11 bits, `line_base` from 9 to 16 bits, covering the full 64KB DDR.

### 2.2 UART_BASE Fix

**File:** `main.c`

The command processor firmware used `UART_BASE = 0x10000000` but the actual UART is at `0x40001000` (via MMIO bridge at `0x40000000`).

### 2.3 Simulation Linker Script

**File:** `link_sim.ld`

- ORIGIN: `0x00000000` (matches CPU0 reset PC)
- LENGTH: 60KB (within 64KB DDR)
- `_stack_end = 0xF000` (top of DDR)

---

## 3. Verilator Boot Verification Results

### 3.1 Boot Sequence

The GRX930 SoC boots correctly with L2 enabled:

1. CPU0 starts at PC=0x0 (DDR_BASE)
2. Executes `_start_text`: sets up stack pointer from GOT
3. Calls `startup_c`: clears BSS (0x6C8–0xAE0)
4. Initializes UART (115200 baud)
5. Sends boot banner via UART
6. Enters command processor loop

### 3.2 UART Echo Tests — 4/4 PASS

| Test | Input | Expected | Got | Status |
|------|-------|----------|-----|--------|
| PING | 'P' | "PONGA" | "PONGA" | ✅ PASS |
| ECHO | 'E' + "Hello" | "HelloA" | "HelloA" | ✅ PASS |
| VERSION | 'V' | "GRX930_ECHO_V1A" | "GRX930_ECHO_V1A" | ✅ PASS |
| UNKNOWN | 'X' | "ERR_UNKNOWN_CMD58E" | "ERR_UNKNOWN_CMD58E" | ✅ PASS |

### 3.3 GEMM Sweep — 18/18 PASS

All tests run on Verilated GRX930 SoC with L2 enabled (BYPASS_L2=0).

| Precision | Shape | Status |
|-----------|-------|--------|
| INT8 | 1×1×1 | ✅ PASS |
| INT8 | 1×1×16 | ✅ PASS |
| INT8 | 1×12×8 | ✅ PASS |
| INT8 | 2×3×5 | ✅ PASS |
| INT8 | 4×4×4 | ✅ PASS |
| INT8 | 5×7×9 | ✅ PASS |
| INT8 | 8×1×4 | ✅ PASS |
| INT8 | 8×4×1 | ✅ PASS |
| INT8 | 8×12×16 | ✅ PASS |
| INT8 | 3×9×11 | ✅ PASS |
| INT16 | 4×4×4 | ✅ PASS |
| INT16 | 2×3×5 | ✅ PASS |
| FP16 | 4×4×4 | ✅ PASS |
| FP16 | 2×3×5 | ✅ PASS |
| BF16 | 4×4×4 | ✅ PASS |
| BF16 | 2×3×5 | ✅ PASS |
| INT4 | 4×4×4 | ✅ PASS |
| INT4 | 2×3×5 | ✅ PASS |

**Total: 18/18 cases PASS** (13.2M cycles)

### 3.4 DDR Traffic Analysis

With the L2 fix, the DDR trace shows the expected pattern:
- One cache line read per 32-byte line (no redundant reads)
- Two AXI writes per 32-byte line (4-byte stores map to 8-byte AXI lanes)
- No spurious invalidations between writes to the same line

---

## 4. Commit History

| Commit | Description |
|--------|-------------|
| d439ecc | L2 self-invalidation fix, DDR address decode, UART_BASE, simulation linker |
| 6ff17a8 | Restore 18-case GEMM sweep to tb_uart_echo.cc |

---

## 5. Remaining Work

1. **Multi-core coherency testing** — Run GEMM sweep on 4-core configuration
2. **FPGA synthesis** — Vivado P&R on Arty A7-200T for timing closure
3. **Large-shape stress test** — K=64/128/256 multi-tile GEMM
4. **ASIC synthesis** — Gate count and timing for 28nm tapeout

---

## Appendix: Reproducing the Verification

```bash
# On server (ubuntu@49.13.6.8):
cd ~/grx930/c930

# Build GEMM firmware
cd sw/firmware && make clean && make TARGET=uart_gemm_test

# Build Verilator SoC (with L2 enabled)
cd ~/grx930/c930
bash sim/build_grx930_verilator.sh

# Run GEMM sweep
cd build/verilator_soc
./Vc930_soc_verilator ~/grx930/c930/sw/firmware/firmware_uart_gemm_test.hex

# Run echo tests
make -C ~/grx930/c930/sw/firmware clean && make -C ~/grx930/c930/sw/firmware TARGET=uart_echo_test
./Vc930_soc_verilator ~/grx930/c930/sw/firmware/firmware_uart_echo_test.hex
```
