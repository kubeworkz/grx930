// perf_only.c — Minimal firmware: just run the NPU perf_bench.
// Skips dcache_stress, trap_test, and run_gemm entirely.
// Used with tb_perf_quick.sv to isolate the MMIO bridge issue.

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

#define CSR_START   1
#define STATUS_DONE 2

#define A_ADDR  0x8000u
#define B_ADDR  0x8400u
#define C_ADDR  0x8800u
#define DONE_ADDR  0x9410u
#define DONE_MAGIC 0xDEADBEEFu
#define PHASE_ADDR 0x9490u

static void run_one_gemm(int m, int n, int k, int prec) {
    volatile u32 *phase = (volatile u32 *)PHASE_ADDR;
    *phase = 0xA0;

    CSR_DIM_M  = m;
    CSR_DIM_N  = n;
    CSR_DIM_K  = k;
    CSR_A_BASE = A_ADDR;
    CSR_B_BASE = B_ADDR;
    CSR_C_BASE = C_ADDR;
    CSR_PREC   = prec;
    {volatile u32 _b; _b = CSR_PREC; (void)_b;}  // barrier

    *phase = 0xA1;
    CSR_CTRL = CSR_START;

    *phase = 0xA2;
    while (!(CSR_STATUS & STATUS_DONE))
        ;
    *phase = 0xA3;
}

__attribute__((noinline))
void main(void) {
    volatile u32 *phase = (volatile u32 *)PHASE_ADDR;

    *phase = 0x01;

    // GEMM 1: M=8 N=8 K=16 INT4
    run_one_gemm(8, 8, 16, 4);

    // Signal done
    *phase = 0x08;
    *(volatile u32 *)DONE_ADDR = DONE_MAGIC;

    // GEMM 2: re-trigger with same params
    *phase = 0x10;
    run_one_gemm(8, 8, 16, 0);

    // GEMM 3: different params
    *phase = 0x20;
    run_one_gemm(4, 4, 8, 1);

    *phase = 0x11;

    for (;;)
        ;
}
