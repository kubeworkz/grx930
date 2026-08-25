// bridge_test2.c — Two consecutive GEMMs via CPU MMIO path.
// Simulates the perf_bench re-trigger scenario: first GEMM completes,
// then immediately program and kick again.

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

#define CSR_START   0x1u
#define STATUS_DONE 0x2u

#define PHASE_ADDR 0x9490
#define DONE_ADDR  0x9410
#define DONE_MAGIC 0xDEADBEEFu

static void run_gemm(int m, int n, int k, int prec)
{
    volatile u32 *phase = (volatile u32 *)PHASE_ADDR;
    *phase = 0x10;
    CSR_DIM_M  = m;
    CSR_DIM_N  = n;
    CSR_DIM_K  = k;
    CSR_A_BASE = 0x8000;
    CSR_B_BASE = 0x8400;
    CSR_C_BASE = 0x8800;
    CSR_PREC   = prec;
    { volatile u32 _b; _b = CSR_PREC; (void)_b; }  // read-back barrier
    CSR_CTRL = CSR_START;
    *phase = 0x11;
    while (!(CSR_STATUS & STATUS_DONE))
        ;
    *phase = 0x12;
}

void main(void)
{
    volatile u32 *phase = (volatile u32 *)PHASE_ADDR;

    *phase = 0x01;

    // First GEMM: M=8 N=8 K=16 INT8
    run_gemm(8, 8, 16, 0);
    *phase = 0x20;

    // Read performance counter between GEMMs
    { volatile u32 cyc; cyc = CSR_CYCLE; (void)cyc; }

    // Second GEMM: same dims, INT8 (simulating perf_bench's next run_perf_case)
    run_gemm(8, 8, 16, 0);
    *phase = 0x30;

    // Third GEMM
    run_gemm(8, 8, 16, 1);  // INT16
    *phase = 0x40;

    // Signal done
    *(volatile u32 *)DONE_ADDR = DONE_MAGIC;
    *phase = 0xFF;

    for (;;)
        ;
}
