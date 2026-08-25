// bridge_test.c — Minimal firmware: just one NPU GEMM via the CPU's MMIO path.
// Tests if the dcache → bridge → CSR path works for a single kick.
// No stress tests, no perf_bench, no traps — just CSR writes + poll.

typedef unsigned int u32;

#define MMIO_BASE 0x40000000u
#define CSR_CTRL    (*(volatile u32 *)(MMIO_BASE + 0x00))
#define CSR_STATUS  (*(volatile u32 *)(MMIO_BASE + 0x04))
#define CSR_DIM_M   (*(volatile u32 *)(MMIO_BASE + 0x08))
#define CSR_DIM_N   (*(volatile u32 *)(MMIO_BASE + 0x0C))
#define CSR_DIM_K   (*(volatile u32 *)(MMIO_BASE + 0x10))
#define CSR_A_BASE  (*(volatile u32 *)(MMIO_BASE + 0x14))
#define CSR_B_BASE  (*(volatile u32 *)(MMIO_BASE + 0x18))
#define CSR_C_BASE  (*(volatile u32 *)(MMIO_BASE + 0x1C))
#define CSR_PREC    (*(volatile u32 *)(MMIO_BASE + 0x20))
#define CSR_CYCLE   (*(volatile u32 *)(MMIO_BASE + 0x24))
#define CSR_OP_CNT  (*(volatile u32 *)(MMIO_BASE + 0x2C))
#define CSR_STALL   (*(volatile u32 *)(MMIO_BASE + 0x30))

#define CSR_START   0x1u
#define STATUS_DONE 0x2u

#define PHASE_ADDR 0x9490
#define DONE_ADDR  0x9410
#define DONE_MAGIC 0xDEADBEEFu

void main(void)
{
    volatile u32 *phase = (volatile u32 *)PHASE_ADDR;

    // Phase 1: programming
    *phase = 0x01;
    CSR_DIM_M  = 8;
    CSR_DIM_N  = 8;
    CSR_DIM_K  = 16;
    CSR_A_BASE = 0x8000;
    CSR_B_BASE = 0x8400;
    CSR_C_BASE = 0x8800;
    CSR_PREC   = 0;

    // Read-back barrier
    { volatile u32 _b; _b = CSR_PREC; (void)_b; }

    // Phase 2: kick
    *phase = 0x02;
    CSR_CTRL = CSR_START;

    // Phase 3: poll for done
    *phase = 0x03;
    while (!(CSR_STATUS & STATUS_DONE))
        ;

    // Phase 4: done
    *phase = 0x04;
    *(volatile u32 *)DONE_ADDR = DONE_MAGIC;

    // Phase 5: idle
    *phase = 0x05;
    for (;;)
        ;
}
