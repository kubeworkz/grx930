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
