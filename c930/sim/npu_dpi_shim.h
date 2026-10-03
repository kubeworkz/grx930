// -----------------------------------------------------------------------------
// npu_dpi_shim.h - Standalone NPU register/DDR shim for grxcp testing.
//
// Pure-C register-model-accurate NPU.  No Verilator, no simulation kernel.
// The grxcp team links against this to exercise their NPU backend against
// a register-model-accurate NPU without needing Verilator or RTL.
//
// Build:
//   gcc -c npu_dpi_shim.c && ar rcs libnpu_dpi_shim.a npu_dpi_shim.o
//   # or shared:
//   gcc -shared -o libnpu_dpi_shim.so -fPIC npu_dpi_shim.c
//
// Usage:
//   #include "npu_dpi_shim.h"
//   npu_dpi_init();
//   npu_dpi_csr_write(NPU_CSR_DIM_M, 8);
//   npu_dpi_csr_write(NPU_CSR_DIM_N, 8);
//   npu_dpi_csr_write(NPU_CSR_DIM_K, 16);
//   npu_dpi_csr_write(NPU_CSR_A_BASE, 0x8000);
//   npu_dpi_csr_write(NPU_CSR_B_BASE, 0x8400);
//   npu_dpi_csr_write(NPU_CSR_C_BASE, 0x8800);
//   npu_dpi_csr_write(NPU_CSR_PREC, 0);      // INT8
//   npu_dpi_csr_write(NPU_CSR_CTRL, 1);       // trigger GEMM
//   npu_dpi_run(10000);
//   int done = npu_dpi_csr_read(NPU_CSR_STATUS) & 2;
//
// CSR addresses match c930_npu_csr.sv (the RTL register block).
// DDR is a flat 64KB byte array.  All DDR access is bounds-checked.
//
// The NPU state machine runs on npu_dpi_run() calls.  It is NOT cycle-
// accurate, but it IS register-model-accurate: STATUS, CYCLE_COUNT,
// OP_COUNT, and STALL_COUNT update correctly for the configured dims.
//
// STATUS register layout (bitfield, matches RTL):
//   bit 0 = BUSY   (asserted for a few cycles after CTRL.START, before DONE)
//   bit 1 = DONE   (set when GEMM completes)
//   bit 2 = ERROR  (set on address overflow)
// -----------------------------------------------------------------------------

#ifndef NPU_DPI_SHIM_H
#define NPU_DPI_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- CSR addresses (must match c930_npu_csr.sv localparam addresses) ----
//
// Index map (from RTL):
//   0  0x00  CTRL         write-only, bit 0 = start
//   1  0x04  STATUS       read: {29'd0, error, done, busy}
//   2  0x08  DIM_M
//   3  0x0C  DIM_N
//   4  0x10  DIM_K
//   5  0x14  A_BASE
//   6  0x18  B_BASE
//   7  0x1C  C_BASE
//   8  0x20  PREC
//   9  0x24  CYCLE_LO     free-running cycle counter (low)
//  10  0x28  (reserved)   dead code — ADDR_CYCLE_HI defined in RTL but
//                          not wired in any case statement, always reads 0
//  11  0x2C  OP_COUNT     MAC operations completed
//  12  0x30  STALL_COUNT  cycles stalled
//  13  0x34  DMA_CT       DMA busy cycles
//
#define NPU_CSR_CTRL      0x40000000u
#define NPU_CSR_STATUS    0x40000004u
#define NPU_CSR_DIM_M     0x40000008u
#define NPU_CSR_DIM_N     0x4000000cu
#define NPU_CSR_DIM_K     0x40000010u
#define NPU_CSR_A_BASE    0x40000014u
#define NPU_CSR_B_BASE    0x40000018u
#define NPU_CSR_C_BASE    0x4000001cu
#define NPU_CSR_PREC      0x40000020u
#define NPU_CSR_CYCLE     0x40000024u   // CYCLE_LO (read cycle count here)
#define NPU_CSR_OP_COUNT  0x4000002cu
#define NPU_CSR_STALL     0x40000030u
#define NPU_CSR_DMA_CT    0x40000034u

// Legacy aliases for code that used the old (wrong) names
#define NPU_REG_CTRL      NPU_CSR_CTRL
#define NPU_REG_STATUS    NPU_CSR_STATUS
#define NPU_REG_DIM_M     NPU_CSR_DIM_M
#define NPU_REG_DIM_N     NPU_CSR_DIM_N
#define NPU_REG_DIM_K     NPU_CSR_DIM_K
#define NPU_REG_A_BASE    NPU_CSR_A_BASE
#define NPU_REG_B_BASE    NPU_CSR_B_BASE
#define NPU_REG_C_BASE    NPU_CSR_C_BASE
#define NPU_REG_PREC      NPU_CSR_PREC

// ---- The PTA register block (c930_npu_csr.sv, 0x100-0x1FC) ----
//
// The RTL's register file carries this block in EVERY build, with a photonic
// tile or without one, and its configuration registers write and read back the
// same either way.  What tells the builds apart is four read-only words at the
// head of the block, and the refusal: a core with no tile refuses any START
// that asks for an impairment, because running it would return an exact GEMM
// under an analog label.
//
// BY DEFAULT THIS MODEL IS A BUILD WITH NO TILE.  It computes C = A x B exactly,
// in a C triple loop, so it answers as the digital array does:
//
//   PTA_ID      the magic and the map version, as the RTL's
//   PTA_CAPS0   this model's geometry -- its own, see below
//   PTA_CAPS1   no impairment built; the weight banks
//   PTA_CAPS2   zero: no calibration engine, no activation stage, no tile
//   PTA_IMPAIR, PTA_BITS, PTA_SEED, the three sigmas, PTA_DRIFT, PTA_XTALK,
//   PTA_DRIFT_MAX
//               stored and read back, at the RTL's field widths
//   PTA_CTRL    bit 0 (EN) is stored and read back and enables nothing, there
//               being no engine.  Bit 3 (MODEL_RST) is a pulse.  Every other
//               bit reads zero.
//   PTA_STATUS  bit 4, the engine's BUSY, and bit 2, SAT (PTA_SAT_CT != 0)
//   PTA_WLOAD_CT  weight programmings, one per (N tile, K tile), cumulative
//
// and a START with PTA_IMPAIR non-zero is REFUSED: STATUS.ERROR, no DONE, C
// untouched.  Every other word of the block reads zero and ignores writes.
//
// IT CAN ALSO BE A BUILD WITH A TILE, if it is compiled with NPU_DPI_WITH_PTA
// and linked with sim/pta_tile_model.c, and npu_dpi_set_tile() asks for one.
// The tile is that file -- the C reference rtl/pta/c930_ptm_c.sv is held to
// bit for bit (make core_pta_gates) -- reached through these registers.  Then:
//
//   PTA_CAPS1   every impairment but MZM_NL built, as the RTL's tile reports
//   PTA_CAPS2   an emulated tile of kind 3: the reference model on its own,
//               with no tile's timing behind it.  No RTL build reports 3.
//               Still no calibration engine and no activation stage.
//   a START     with PTA_IMPAIR set RUNS, through pta_gemm(), and C is the
//               impaired result.  It is refused exactly where the core refuses
//               it: a bit outside the built mask, FP16 or BF16, or S above 40.
//   PTA_SHOT_CT   M shots per (N tile, K tile), cumulative
//   PTA_SAT_CT    ADC saturations in the last GEMM
//   MODEL_RST     returns drift to zero and reloads its generator from PTA_SEED
//
// Drift is device state and survives from one GEMM to the next, as it does in
// the RTL, until MODEL_RST or npu_dpi_init().  The weight bank is always 0:
// this model has no command queue, and the RTL's bank only flips when a queued
// GEMM is prefetched behind the running one.
//
// WHAT THE TILE BUILD STILL IS NOT.  It has no calibration engine (PTA_CAL_*,
// PTA_GAIN, PTA_OFFS, PTA_TRIM read zero), none of PTA_CTRL's loop-order or
// residency modes, and no timing: PTA_TW and PTA_TS read zero and the cycle
// counters are the ones grxcp's gap register already says not to quote.  It is
// the model's arithmetic behind the register map, and nothing more.
//
// CAPS0 reports THIS MODEL'S geometry, which is the 4 x 4 array its cycle model
// has always used, and not the SoC's: c930_soc_top has been 8 x 8 since the
// array was widened.  That divergence predates this block and is the reason
// the word exists -- a driver reads the geometry instead of assuming it.
#define NPU_CSR_PTA_ID        0x40000100u   // R:  [31:8] "PTA", [7:0] map version
#define NPU_CSR_PTA_CAPS0     0x40000104u   // R:  [9:0] rows [19:10] cols [25:20] DIN_W [31:26] ACC_W
#define NPU_CSR_PTA_CAPS1     0x40000108u   // R:  [6:0] impairments built [15:8] banks, widest bits above
#define NPU_CSR_PTA_CAPS2     0x4000010cu   // R:  [16] cal engine [17] act stage [19:18] tile [31] emulated
#define NPU_CSR_PTA_CTRL      0x40000140u   // RW: [0] EN
#define NPU_CSR_PTA_STATUS    0x40000144u   // R:  [4] BUSY
#define NPU_CSR_PTA_IMPAIR    0x40000148u   // RW: [6:0] one bit per impairment
#define NPU_CSR_PTA_BITS      0x4000014cu   // RW: [3:0] B_a [7:4] B_w [11:8] B_adc [17:12] S
#define NPU_CSR_PTA_SEED      0x40000150u   // RW
#define NPU_CSR_PTA_SIGMA_TH  0x40000154u   // RW: [15:0] thermal sigma, Q8.8 ADC LSB
#define NPU_CSR_PTA_SIGMA_SH  0x40000158u   // RW: [15:0] shot coefficient k, Q8.8
#define NPU_CSR_PTA_SIGMA_PR  0x4000015cu   // RW: [15:0] programming sigma, Q8.8 weight LSB
#define NPU_CSR_PTA_DRIFT     0x40000160u   // RW: [15:0] step sigma Q8.8, [20:16] log2 shots a step
#define NPU_CSR_PTA_XTALK     0x40000164u   // RW: [7:0] chi, Q0.8
#define NPU_CSR_PTA_SHOT_CT   0x40000180u   // R:  optical shots issued (a tile build only)
#define NPU_CSR_PTA_WLOAD_CT  0x40000184u   // R:  weight-bank programmings
#define NPU_CSR_PTA_SAT_CT    0x40000188u   // R:  ADC saturations, the last GEMM
#define NPU_CSR_PTA_DRIFT_MAX 0x400001d0u   // RW: [15:0] drift clamp, Q8.8 weight LSB

#define NPU_PTA_ID_VALUE      0x50544101u   // "PTA", map version 1
#define NPU_PTA_ID_MAGIC      0x50544100u
#define NPU_PTA_CTRL_EN        0x01u
#define NPU_PTA_CTRL_MODEL_RST 0x08u
#define NPU_PTA_STATUS_SAT    0x04u
#define NPU_PTA_STATUS_BUSY   0x10u

// ---- What the model is built as ----
// A build, not a state: npu_dpi_init() resets the registers and the device and
// leaves this alone, the way a reset does not change what a chip is.
#define NPU_DPI_TILE_NONE     0   // the digital array (the default)
#define NPU_DPI_TILE_MODEL    3   // the tile: pta_tile_model.c behind the registers

// ---- DDR size (must match c930_ddr.sv MEM_BYTES) ----
#define NPU_DDR_SIZE      65536

// ---- Backend type hints (for grxcp device enumeration) ----
// These describe the *type* of register model attached to the NPU device.
// The mapping into grxBackend_t belongs on the grxcp side, next to the
// seam that attaches the model.  Do NOT assign these values directly to
// grxDeviceProp_t.backend — use grxcp's own enum instead.
//
// grxcp mapping (from their enum: SIMX=0, RTLSIM=1, XRT=2, ... SILICON=5):
//   NPU_DPI_BACKEND_EMULATION  → new value (e.g. GRX_BACKEND_NPU_SHIM)
//   NPU_DPI_BACKEND_SIMULATION → GRX_BACKEND_RTLSIM (existing)
//   real hardware              → GRX_BACKEND_SILICON (existing)
#define NPU_DPI_BACKEND_EMULATION  0x10  // shim / software register model
#define NPU_DPI_BACKEND_SIMULATION 0x11  // Verilator / RTL-backed sim

// ---- Precision constants (must match c930_npu_core.sv) ----
#define NPU_PREC_INT8     0
#define NPU_PREC_INT16    1
#define NPU_PREC_FP16     2
#define NPU_PREC_BF16     3
#define NPU_PREC_INT4     4

// ---- Status bitfield ----
#define NPU_STATUS_BUSY   0x01
#define NPU_STATUS_DONE   0x02
#define NPU_STATUS_ERROR  0x04

// ---- DPI functions (compatible with npu_dpi.h signatures) ----

// Choose the build.  Call it before npu_dpi_init(), which then brings the
// chosen build up from reset.  Returns 0, or -1 if the kind is unknown, if this
// library was compiled without NPU_DPI_WITH_PTA and a tile was asked for, or if
// the tile's state could not be allocated -- and in each of those cases the
// build is left as it was.
int npu_dpi_set_tile(int kind);

// The build in force: NPU_DPI_TILE_NONE or NPU_DPI_TILE_MODEL.
int npu_dpi_tile(void);

// Reset all CSR and DDR state to zero.
void npu_dpi_init(void);

// CSR access
void npu_dpi_csr_write(uint32_t addr, uint32_t data);
uint32_t npu_dpi_csr_read(uint32_t addr);

// DDR byte access (bounds-checked, returns ERROR on overflow)
void npu_dpi_mem_write(uint32_t addr, uint32_t data, uint32_t strb);
int npu_dpi_mem_read(uint32_t addr);

// Advance the NPU state machine by n_cycles.
// Call this after triggering (CTRL = 1) to simulate GEMM execution.
// STATUS.BUSY is asserted for the first few cycles, then STATUS.DONE
// is set when the GEMM completes.
void npu_dpi_run(int n_cycles);

// Compute the expected cycle count for the current dims/precision.
// Useful for knowing how many npu_dpi_run() calls are needed.
int npu_dpi_expected_cycles(void);

// ---- Convenience: high-level GEMM in one call ----
// Configures CSRs, triggers, runs to completion.
// Returns the number of simulated cycles used.
// This function DOES write CTRL.START (fixes the original bug).
int npu_dpi_run_gemm(uint32_t m, uint32_t n, uint32_t k, uint32_t prec,
                     uint32_t a_addr, uint32_t b_addr, uint32_t c_addr);

#ifdef __cplusplus
}
#endif

#endif // NPU_DPI_SHIM_H
