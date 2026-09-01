// -----------------------------------------------------------------------------
// npu_dpi_shim.h - Standalone NPU register/DDR shim for grxcp testing.
//
// This is a pure-C implementation of the dpi_npu_* interface that stores
// CSR state and DDR in plain arrays. No Verilator, no simulation kernel.
// The grxcp team links against this to exercise their NPU backend against
// a register-model-accurate NPU without needing Verilator.
//
// Build:
//   gcc -shared -o libnpu_dpi_shim.so -fPIC npu_dpi_shim.c
//   # or for static linking:
//   gcc -c npu_dpi_shim.c && ar rcs libnpu_dpi_shim.a npu_dpi_shim.o
//
// Usage:
//   #include "npu_dpi_shim.h"
//   npu_dpi_init();                          // reset all state
//   npu_dpi_csr_write(NPU_REG_DIM_M, 8);    // configure NPU
//   npu_dpi_mem_write(0x8000, 0x42, 0xFF);   // load A[0]
//   npu_dpi_csr_write(NPU_REG_CTRL, 1);      // trigger GEMM
//   npu_dpi_run(10000);                       // advance 10K cycles
//   int done = npu_dpi_csr_read(NPU_REG_STATUS) & 2;
//
// CSR addresses match c930_npu_csr.sv. DDR is a flat 64KB byte array.
// The NPU state machine runs on npu_dpi_run() calls — it is NOT cycle-
// accurate, but it IS register-model-accurate: STATUS, CYCLE_COUNT,
// OP_COUNT, and STALL_COUNT update correctly for the configured dims.
// -----------------------------------------------------------------------------

#ifndef NPU_DPI_SHIM_H
#define NPU_DPI_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- CSR addresses (must match c930_npu_csr.sv) ----
#define NPU_CSR_CTRL    0x40000000u
#define NPU_CSR_STATUS  0x40000004u
#define NPU_CSR_DIM_M   0x40000008u
#define NPU_CSR_DIM_N   0x4000000cu
#define NPU_CSR_DIM_K   0x40000010u
#define NPU_CSR_A_BASE  0x40000014u
#define NPU_CSR_B_BASE  0x40000018u
#define NPU_CSR_C_BASE  0x4000001cu
#define NPU_CSR_PREC    0x40000020u
#define NPU_CSR_CYCLE   0x40000024u
#define NPU_CSR_OP_CNT  0x4000002cu
#define NPU_CSR_STALL   0x40000030u
#define NPU_CSR_DMA_CT  0x40000034u

// ---- DPI functions (compatible with npu_dpi.h signatures) ----

// Reset all CSR and DDR state to zero.
void npu_dpi_init(void);

// CSR access
void npu_dpi_csr_write(uint32_t addr, uint32_t data);
uint32_t npu_dpi_csr_read(uint32_t addr);

// DDR byte access
void npu_dpi_mem_write(uint32_t addr, uint32_t data, uint32_t strb);
int npu_dpi_mem_read(uint32_t addr);

// Advance the NPU state machine by `n` cycles.
// Call this after triggering (CSR_CTRL = 1) to simulate the GEMM execution.
// The NPU will set STATUS.DONE after the computed number of cycles.
void npu_dpi_run(int n_cycles);

// Compute the expected cycle count for the current dims/precision.
// Useful for知道 how many npu_dpi_run() calls are needed.
int npu_dpi_expected_cycles(void);

// ---- Convenience: high-level GEMM in one call ----
// Loads A/B from DDR, configures CSRs, triggers, runs to completion.
// Returns the number of simulated cycles used.
int npu_dpi_run_gemm(uint32_t m, uint32_t n, uint32_t k, uint32_t prec,
                     uint32_t a_addr, uint32_t b_addr, uint32_t c_addr);

#ifdef __cplusplus
}
#endif

#endif // NPU_DPI_SHIM_H
