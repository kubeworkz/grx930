// -----------------------------------------------------------------------------
// c930_npu_driver.c - Host-side driver for the C930 NPU command queue.
//
// See c930_npu_driver.h for the API, register map, and completion-contract
// notes. This file has no dependencies other than <stdint.h> and the two
// accessors wired by npu_drv_init()/npu_drv_mmio(), so it is safe to vendor
// into any host (grxcp Verilator backend, RISC-V firmware, PCIe stub).
// -----------------------------------------------------------------------------

#include "c930_npu_driver.h"

// ---- IO plumbing ----

static npu_drv_read_fn  s_read  = 0;
static npu_drv_write_fn s_write = 0;
static uint32_t         s_mmio_base = 0;
static int              s_use_mmio  = 0;

static inline uint32_t drv_read(uint32_t addr)
{
    if (s_use_mmio)
        return *(volatile uint32_t *)(s_mmio_base + addr);
    return s_read(addr);
}

static inline void drv_write(uint32_t addr, uint32_t val)
{
    if (s_use_mmio)
        *(volatile uint32_t *)(s_mmio_base + addr) = val;
    else
        s_write(addr, val);
}

void npu_drv_init(npu_drv_read_fn read_fn, npu_drv_write_fn write_fn)
{
    s_read      = read_fn;
    s_write     = write_fn;
    s_use_mmio  = 0;
}

void npu_drv_mmio(uint32_t base)
{
    s_mmio_base = base;
    s_use_mmio  = 1;
}

// ---- Queue / status ----

int npu_drv_queue_occupancy(void)
{
    return (int)(drv_read(NPU_REG_QUEUE_STAT) & NPU_QUEUE_OCC_MASK);
}

int npu_drv_queue_room(void)
{
    int occ = npu_drv_queue_occupancy();
    int room = NPU_QUEUE_DEPTH - occ;
    return room < 0 ? 0 : room;
}

uint32_t npu_drv_status(void)
{
    return drv_read(NPU_REG_STATUS);
}

int npu_drv_error(void)
{
    return (npu_drv_status() & NPU_STATUS_ERROR) ? 1 : 0;
}

// ---- Submission ----

static int dims_ok(const npu_drv_gemm_t *g)
{
    return g->dim_m >= 1 && g->dim_m <= NPU_MAX_M &&
           g->dim_n >= 1 && g->dim_n <= NPU_MAX_N &&
           g->dim_k >= 1 && g->dim_k <= NPU_MAX_K &&
           (g->a_base & 0x3u) == 0 &&
           (g->b_base & 0x3u) == 0 &&
           (g->c_base & 0x3u) == 0;
}

int npu_drv_submit_at(uint32_t base, const npu_drv_gemm_t *g)
{
    if (!dims_ok(g))
        return -2;

    // START against a full FIFO is silently dropped (1-cycle pulse, push
    // requires space the same cycle). Refuse before submitting.
    if (drv_read(base + 0x38) & NPU_QUEUE_FULL)
        return -1;

    drv_write(base + 0x08, g->dim_m);
    drv_write(base + 0x0c, g->dim_n);
    drv_write(base + 0x10, g->dim_k);
    drv_write(base + 0x14, g->a_base);
    drv_write(base + 0x18, g->b_base);
    drv_write(base + 0x1c, g->c_base);
    drv_write(base + 0x20, g->prec);

    // Last: START snapshots the registers into the FIFO and (re)clears
    // DONE/ERROR. By this point the register writes above have settled.
    drv_write(base + 0x00, NPU_CTRL_START);
    return 0;
}

int npu_drv_submit(const npu_drv_gemm_t *g)
{
    return npu_drv_submit_at(NPU0_BASE, g);
}

// ---- Completion ----

int npu_drv_wait_done(uint64_t timeout_cycles)
{
    uint64_t t = 0;

    while (!(npu_drv_status() & NPU_STATUS_DONE)) {
        if (timeout_cycles != NPU_DRV_TIMEOUT_FOREVER && ++t > timeout_cycles)
            return -1;
    }
    // DONE latches as soon as the DMA finishes the command; BUSY may still
    // be 1 for the C-writeback drain / status handshake.
    while (npu_drv_status() & NPU_STATUS_BUSY) {
        if (timeout_cycles != NPU_DRV_TIMEOUT_FOREVER && ++t > timeout_cycles)
            return -1;
    }
    return 0;
}

int npu_drv_drain(uint64_t timeout_cycles)
{
    uint64_t t = 0;

    // Queue empty AND engine idle. See header: each condition alone is
    // insufficient (occupancy==0 with the last command still running;
    // busy==0 in the dispatch bubble with commands still queued).
    while (npu_drv_queue_occupancy() != 0 || (npu_drv_status() & NPU_STATUS_BUSY)) {
        if (timeout_cycles != NPU_DRV_TIMEOUT_FOREVER && ++t > timeout_cycles)
            return -1;
    }
    return 0;
}

// ---- Performance counters ----

void npu_drv_get_stats(npu_drv_stats_t *st)
{
    st->core_cycles = drv_read(NPU_REG_CYCLE_LO);
    st->dma_last    = drv_read(NPU_REG_DMA_LAST);
    st->ops         = drv_read(NPU_REG_OP_COUNT);
    st->stalls      = drv_read(NPU_REG_STALL_CT);
    st->dma_cycles  = drv_read(NPU_REG_DMA_CT);
}