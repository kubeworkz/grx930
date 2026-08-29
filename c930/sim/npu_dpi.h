// npu_dpi.h - C++ API for NPU register access and DDR memory.
// Include this in grxcp backend code to test against RTL.

#ifndef NPU_DPI_H
#define NPU_DPI_H

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

// ---- CSR addresses ----
#define NPU_CSR_START    0x00
#define NPU_CSR_STATUS   0x04
#define NPU_CSR_DIM_M    0x08
#define NPU_CSR_DIM_N    0x0C
#define NPU_CSR_DIM_K    0x10
#define NPU_CSR_A_BASE   0x14
#define NPU_CSR_B_BASE   0x18
#define NPU_CSR_C_BASE   0x1C
#define NPU_CSR_PREC     0x20
#define NPU_CSR_DONE     0x24
#define NPU_CSR_ERROR    0x28
#define NPU_CSR_CYCLE    0x2C
#define NPU_CSR_OPS      0x30
#define NPU_CSR_STALLS   0x34

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
