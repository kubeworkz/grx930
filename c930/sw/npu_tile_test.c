// -----------------------------------------------------------------------------
// npu_tile_test.c - Tiling test firmware for the C930 NPU.
//
// The testbench pre-fills A/B into DDR and writes dims to DIMS_ADDR.
// This firmware reads the dims, programs the NPU, triggers the GEMM,
// and signals DONE. The testbench then verifies C against its reference.
//
// For tiling tests where dims exceed MAX_M/N/K, the firmware uses the
// tiling library to split the GEMM into multiple NPU invocations.
// The A/B data must be large enough for the full GEMM.
//
// DDR layout (byte addresses):
//   0x1000-0x1FFF: A matrix (M*K bytes, INT8 row-major)
//   0x2000-0x2FFF: B matrix (K*N bytes, INT8 row-major)
//   0x3000-0x3FFF: C result (M*N*4 bytes, INT32 row-major)
//   0x9400-0x940F: dims descriptor (M, N, K, prec)
//   0x9410: DONE magic
//   0x9420: RESULT (PASS/FAIL magic)
//   0x9490: PHASE
//   0x9480: DIAG
// -----------------------------------------------------------------------------

typedef unsigned int u32;

// DDR addresses
#define A_ADDR      0x1000
#define B_ADDR      0x2000
#define C_ADDR      0x3000
#define DIMS_ADDR   0x9400
#define DONE_ADDR   0x9410
#define DONE_MAGIC  0xDEADBEEFu
#define RESULT_ADDR 0x9420
#define PASS_MAGIC  0x0BADBEEFu
#define FAIL_MAGIC  0xBADF00Du
#define PHASE_ADDR  0x9490
#define DIAG_ADDR   0x9480

// NPU MMIO
#define MMIO_BASE 0x40000000u
#define CSR_DIM_M   (*(volatile u32 *)(MMIO_BASE + 0x08))
#define CSR_DIM_N   (*(volatile u32 *)(MMIO_BASE + 0x0C))
#define CSR_DIM_K   (*(volatile u32 *)(MMIO_BASE + 0x10))
#define CSR_A_BASE  (*(volatile u32 *)(MMIO_BASE + 0x14))
#define CSR_B_BASE  (*(volatile u32 *)(MMIO_BASE + 0x18))
#define CSR_C_BASE  (*(volatile u32 *)(MMIO_BASE + 0x1C))
#define CSR_PREC    (*(volatile u32 *)(MMIO_BASE + 0x20))
#define CSR_CTRL    (*(volatile u32 *)(MMIO_BASE + 0x00))
#define CSR_STATUS  (*(volatile u32 *)(MMIO_BASE + 0x04))
#define CSR_START   0x1u
#define STATUS_DONE 0x2u

// Hardware limits
#define MAX_M   8
#define MAX_N   12
#define MAX_K   16

// Tiling scratch buffer (above A/B/C buffers, below stack at 0x8000)
#define TMP_ADDR 0x5000

// NPU accessor functions for tiling library
static u32 npu_read(u32 addr) { return *(volatile u32 *)addr; }
static void npu_write(u32 addr, u32 val) { *(volatile u32 *)addr = val; }

// Tiling library API
extern void npu_tile_init(void *read_fn, void *write_fn);
extern void npu_tile_gemm(int M, int N, int K, int prec,
                          u32 a_src, u32 b_src, u32 c_dst, u32 tmp_buf);

__attribute__((noreturn))
void main(void) {
    volatile u32 *phase = (volatile u32 *)PHASE_ADDR;
    volatile u32 *diag  = (volatile u32 *)DIAG_ADDR;

    // Initialize tiling library
    npu_tile_init(npu_read, npu_write);

    // Read dims from testbench-provided descriptor
    u32 m    = *(volatile u32 *)(DIMS_ADDR + 0x00);
    u32 n    = *(volatile u32 *)(DIMS_ADDR + 0x04);
    u32 k    = *(volatile u32 *)(DIMS_ADDR + 0x08);
    u32 prec = *(volatile u32 *)(DIMS_ADDR + 0x0C);

    *phase = 0xF1;

    // Check if tiling is needed
    if (m <= MAX_M && n <= MAX_N && k <= MAX_K) {
        // Fits in one NPU invocation — use direct path
        *phase = 0xF2;
        CSR_DIM_M  = m;
        CSR_DIM_N  = n;
        CSR_DIM_K  = k;
        CSR_A_BASE = A_ADDR;
        CSR_B_BASE = B_ADDR;
        CSR_C_BASE = C_ADDR;
        CSR_PREC   = prec;
        { volatile u32 _b; _b = CSR_PREC; (void)_b; }
        CSR_CTRL = CSR_START;
        while (!(CSR_STATUS & STATUS_DONE))
            ;
    } else {
        // Needs tiling — use the library
        *phase = 0xF3;
        npu_tile_gemm(m, n, k, prec, A_ADDR, B_ADDR, C_ADDR, TMP_ADDR);
    }

    *phase = 0xFE;
    // Signal completion
    *(volatile u32 *)DONE_ADDR = DONE_MAGIC;
    *phase = 0xFF;

    for (;;)
        ;
}
