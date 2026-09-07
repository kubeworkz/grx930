// -----------------------------------------------------------------------------
// c930_npu_driver.h - Host-side driver for the C930 NPU command queue.
//
// Vendor-ready for the grxcp backend. Implements the completion contract
// documented in doc/c930_architecture.md ("Command queue and completion
// contract") and doc/phase7_integration_guide.md:
//
//   * DONE is a latched LEVEL, not a per-command edge: it is set by the first
//     GEMM that completes and cleared ONLY by a START write. It cannot tell
//     you which queued command finished.
//   * BUSY is per-command: it drops to 0 in the short bubble between a queued
//     command's completion and the next dispatch, even when the FIFO still
//     holds commands.
//   * Therefore, for a BATCH of queued commands, poll the queue itself:
//
//         while (queue_occupancy() != 0 || status_busy()) ;
//
//     Neither condition alone is sufficient (occupancy==0 can coincide with
//     the last command still running; busy==0 can coincide with commands
//     still queued). This is npu_drv_drain().
//   * For ONE command at a time, DONE->!BUSY after the START write is safe
//     (the START cleared DONE). This is npu_drv_wait_done().
//   * START is a 1-cycle pulse whose queue push needs FIFO space the SAME
//     cycle: a START against a full FIFO is silently dropped, never deferred.
//     Check queue_room() > 0 before submitting (npu_drv_submit does).
//
// IO abstraction: the driver knows nothing about the bus. You provide
// 32-bit read/write callbacks that receive the FULL byte address
// (NPU base + register offset). Three ways to wire it:
//
//   1. RISC-V firmware (MMIO at fixed base):
//        npu_drv_mmio(NPU0_BASE);          // volatile-pointer accessors
//   2. Verilator host (like grxcp):
//        npu_drv_init(my_read32, my_write32);
//   3. Multiple NPUs: keep one callback pair; pass base per call:
//        npu_drv_submit_at(NPU1_BASE, &gemm);
//
// Example (batch of 3 queued GEMMs, then drain):
//
//     npu_drv_mmio(NPU0_BASE);
//     for (int i = 0; i < 3; i++)
//         npu_drv_submit(&gemm[i]);            // returns -1 if queue full
//     if (npu_drv_drain(NPU_DRV_TIMEOUT_FOREVER))
//         npu_drv_get_stats(&st);              // cycles, OP_COUNT, DMA_CT...
//     if (npu_drv_error()) ...                 // invalid dims latched
//
// -----------------------------------------------------------------------------

#ifndef C930_NPU_DRIVER_H
#define C930_NPU_DRIVER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- SoC address map (c930_soc_top.sv MMIO decode) ----
#define NPU0_BASE  0x40000000u
#define NPU1_BASE  0x40000040u

// ---- Register map (c930_npu_csr.sv; byte addresses) ----
#define NPU_REG_CTRL        (NPU0_BASE + 0x00)   // W: [0] START (snapshot+queue; clears DONE/ERROR)
#define NPU_REG_STATUS      (NPU0_BASE + 0x04)   // R: [0] BUSY [1] DONE [2] ERROR
#define NPU_REG_DIM_M       (NPU0_BASE + 0x08)   // R/W: output rows, 1..MAX_M
#define NPU_REG_DIM_N       (NPU0_BASE + 0x0c)   // R/W: output cols, 1..MAX_N
#define NPU_REG_DIM_K       (NPU0_BASE + 0x10)   // R/W: reduction length, 1..MAX_K
#define NPU_REG_A_BASE      (NPU0_BASE + 0x14)   // R/W: A matrix DDR address (word-aligned)
#define NPU_REG_B_BASE      (NPU0_BASE + 0x18)   // R/W: B matrix DDR address (word-aligned)
#define NPU_REG_C_BASE      (NPU0_BASE + 0x1c)   // R/W: C result DDR address (word-aligned)
#define NPU_REG_PREC        (NPU0_BASE + 0x20)   // R/W: [2:0] precision (see NPU_PREC_*)
#define NPU_REG_CYCLE_LO    (NPU0_BASE + 0x24)   // R: core cycles (state != S_IDLE), resets on i_start
#define NPU_REG_DMA_LAST    (NPU0_BASE + 0x28)   // R: latched DMA cycle count, last completed GEMM
#define NPU_REG_OP_COUNT    (NPU0_BASE + 0x2c)   // R: PE firings (NUM_ROWS*NUM_COLS per S_RUN cycle)
#define NPU_REG_STALL_CT    (NPU0_BASE + 0x30)   // R: weight-load cycles (S_WLOAD)
#define NPU_REG_DMA_CT      (NPU0_BASE + 0x34)   // R: live DMA busy cycles (phase != P_IDLE)
#define NPU_REG_QUEUE_STAT  (NPU0_BASE + 0x38)   // R: [3:0] occupancy, [4] full
#define NPU_REG_QUEUE_MAX   (NPU0_BASE + 0x3c)   // R: compile-time FIFO depth (CMD_QUEUE_DEPTH)

// ---- CTRL bits ----
#define NPU_CTRL_START      0x1u

// ---- STATUS bits ----
#define NPU_STATUS_BUSY     0x1u
#define NPU_STATUS_DONE     0x2u
#define NPU_STATUS_ERROR    0x4u

// ---- QUEUE_STAT bits ----
#define NPU_QUEUE_OCC_MASK  0xFu
#define NPU_QUEUE_FULL      0x10u

// ---- Precision modes (PREC[2:0]) ----
#define NPU_PREC_INT8   0
#define NPU_PREC_INT16  1
#define NPU_PREC_FP16   2
#define NPU_PREC_BF16   3
#define NPU_PREC_INT4   4

// ---- Hardware limits (RTL defaults; match c930_soc_top.sv) ----
#define NPU_MAX_M   8
#define NPU_MAX_N   12
#define NPU_MAX_K   16
#define NPU_QUEUE_DEPTH 4

// ---- Timeouts ----
#define NPU_DRV_TIMEOUT_FOREVER ((uint64_t)-1ull)

// ---- IO callbacks (receive the full byte address) ----
typedef uint32_t (*npu_drv_read_fn)(uint32_t addr);
typedef void     (*npu_drv_write_fn)(uint32_t addr, uint32_t val);

// ---- One GEMM command ----
typedef struct {
    uint32_t dim_m;    // 1..NPU_MAX_M
    uint32_t dim_n;    // 1..NPU_MAX_N
    uint32_t dim_k;    // 1..NPU_MAX_K
    uint32_t a_base;   // DDR byte address, word-aligned
    uint32_t b_base;   // DDR byte address, word-aligned
    uint32_t c_base;   // DDR byte address, word-aligned
    uint32_t prec;     // NPU_PREC_*
} npu_drv_gemm_t;

// ---- Performance counters (read after drain) ----
typedef struct {
    uint32_t core_cycles;  // CYCLE_LO: core cycles for the LAST command
    uint32_t dma_last;     // DMA_LAST: DMA busy cycles, last completed GEMM
    uint32_t ops;          // OP_COUNT: PE firings, last command
    uint32_t stalls;       // STALL_CT: weight-load cycles, last command
    uint32_t dma_cycles;   // DMA_CT: live DMA busy cycles (read while busy)
} npu_drv_stats_t;

// ---- Initialization ----

// Use the provided bus callbacks (host side: Verilator AXI, PCIe, ...).
void npu_drv_init(npu_drv_read_fn read_fn, npu_drv_write_fn write_fn);

// Use direct volatile-pointer MMIO (RISC-V firmware with the MMIO region
// mapped uncached at 'base'). Reads/writes go to base + offset.
void npu_drv_mmio(uint32_t base);

// ---- Queue / status ----

// Number of free FIFO slots (0 = full). Never negative.
int  npu_drv_queue_room(void);

// Current FIFO occupancy (0..NPU_QUEUE_DEPTH).
int  npu_drv_queue_occupancy(void);

// Raw STATUS register (see NPU_STATUS_*).
uint32_t npu_drv_status(void);

// Latched ERROR bit (invalid dims programmed). Cleared by the next START.
int  npu_drv_error(void);

// ---- Submission ----

// Program DIMs/bases/PREC and write START. Returns 0 on success,
// -1 if the FIFO is full (START would be silently dropped), -2 on
// invalid dimensions. Does NOT block.
int  npu_drv_submit(const npu_drv_gemm_t *g);

// npu_drv_submit at an explicit NPU base (NPU0_BASE / NPU1_BASE).
int  npu_drv_submit_at(uint32_t base, const npu_drv_gemm_t *g);

// ---- Completion ----

// Wait for a SINGLE command (submitted one at a time): DONE latched then
// BUSY clear. Safe because the START write cleared DONE. Returns 0, or -1
// on timeout (use NPU_DRV_TIMEOUT_FOREVER to block).
int  npu_drv_wait_done(uint64_t timeout_cycles);

// Drain a BATCH of queued commands: spin until occupancy==0 && !BUSY.
// The ONLY correct completion test for queued commands (see header top).
// Returns 0, or -1 on timeout (NPU_DRV_TIMEOUT_FOREVER to block).
int  npu_drv_drain(uint64_t timeout_cycles);

// ---- Performance counters ----
void npu_drv_get_stats(npu_drv_stats_t *st);

#ifdef __cplusplus
}
#endif

#endif // C930_NPU_DRIVER_H