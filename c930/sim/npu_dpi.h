// npu_dpi.h - C++ API for NPU register access and DDR memory.
// Include this in grxcp backend code to test against RTL.

#ifndef NPU_DPI_H
#define NPU_DPI_H

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

// ---- CSR addresses (must match c930_npu_csr.sv) ----
// Index map:
//   0  0x00  CTRL         write-only, bit 0 = START
//   1  0x04  STATUS       read: {29'd0, error, done, busy}
//   2  0x08  DIM_M
//   3  0x0C  DIM_N
//   4  0x10  DIM_K
//   5  0x14  A_BASE
//   6  0x18  B_BASE
//   7  0x1C  C_BASE
//   8  0x20  PREC
//   9  0x24  CYCLE_LO     free-running cycle counter (32-bit)
//  10  0x28  (reserved)   dead code, always reads 0
//  11  0x2C  OP_COUNT
//  12  0x30  STALL_COUNT
//  13  0x34  DMA_CT
#define NPU_CSR_CTRL      0x00
#define NPU_CSR_STATUS    0x04
#define NPU_CSR_DIM_M     0x08
#define NPU_CSR_DIM_N     0x0C
#define NPU_CSR_DIM_K     0x10
#define NPU_CSR_A_BASE    0x14
#define NPU_CSR_B_BASE    0x18
#define NPU_CSR_C_BASE    0x1C
#define NPU_CSR_PREC      0x20
#define NPU_CSR_CYCLE     0x24   // CYCLE_LO
#define NPU_CSR_OP_COUNT  0x2C
#define NPU_CSR_STALL     0x30
#define NPU_CSR_DMA_CT    0x34

// STATUS bitfield (read from NPU_CSR_STATUS)
#define NPU_STATUS_BUSY   0x01
#define NPU_STATUS_DONE   0x02
#define NPU_STATUS_ERROR  0x04

// Legacy aliases (deprecated, use NPU_CSR_* names)
#define NPU_CSR_START     NPU_CSR_CTRL
#define NPU_CSR_DONE      NPU_CSR_STATUS  // WRONG — DONE is a STATUS bit, not a register
#define NPU_CSR_ERROR     NPU_CSR_STATUS  // WRONG — ERROR is a STATUS bit, not a register
#define NPU_CSR_CYCLE_OLD NPU_CSR_OP_COUNT // WRONG — was shifted by one in old map

// ---- Precision modes ----
#define NPU_PREC_INT8    0
#define NPU_PREC_INT16   1
#define NPU_PREC_FP16    2
#define NPU_PREC_BF16    3
#define NPU_PREC_INT4    4

// ---- DPI functions (implemented in npu_dpi.cc) ----
void    dpi_npu_csr_write(int addr, int data);
int     dpi_npu_csr_read(int addr);
void    dpi_npu_mem_write(int addr, int data, int strb);
int     dpi_npu_mem_read(int addr);

// ---- High-level API ----
uint8_t* npu_get_ddr_ptr(void);

// ---- Convenience functions ----
static inline void npu_write_csr(int addr, int data) {
    dpi_npu_csr_write(addr, data);
}

static inline int npu_read_csr(int addr) {
    return dpi_npu_csr_read(addr);
}

static inline void npu_write32(int addr, uint32_t val) {
    dpi_npu_mem_write(addr, val, 0xF);
}

static inline uint32_t npu_read32(int addr) {
    return (uint32_t)dpi_npu_mem_read(addr);
}

static inline void npu_write_int8(int addr, int8_t val) {
    dpi_npu_mem_write(addr, val, 0x1);
}

static inline int8_t npu_read_int8(int addr) {
    return (int8_t)dpi_npu_mem_read(addr);
}

static inline void npu_write_int16(int addr, int16_t val) {
    dpi_npu_mem_write(addr, val, 0x3);
}

static inline int16_t npu_read_int16(int addr) {
    return (int16_t)dpi_npu_mem_read(addr);
}

#ifdef __cplusplus
}
#endif

#endif // NPU_DPI_H
