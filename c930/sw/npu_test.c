// -----------------------------------------------------------------------------
// npu_test.c - bare-metal driver for the C930 NPU.
//
// Runs on the RV64IMAC core (no libc, no OS). The INT8 A (MxK) and B (KxN)
// operand tables are linked at fixed DDR addresses (0x9000/0x9100) and are part
// of the flat image the testbench loads into DDR, so this driver performs NO
// data staging: the NPU's AXI4 DMA master fetches A and B autonomously from
// DDR, runs the GEMM, and burst-writes C (MxN INT32) back to DDR. The core
// only:
//   1. programs the NPU control/status registers over MMIO,
//   2. launches the GEMM and polls STATUS.DONE,
//   3. writes a completion magic to DDR (the testbench then checks C).
//
// GEMM: C[MxN] = A[MxK] x B[KxN], INT8 inputs, INT32 outputs.
// -----------------------------------------------------------------------------

typedef unsigned int u32;
typedef signed char   i8;

#define M 2
#define N 6
#define K 8

// -----------------------------------------------------------------------------
// DDR data buffers (flat byte addresses, shared with the NPU AXI4 master)
// -----------------------------------------------------------------------------
#define A_ADDR    0x9000
#define B_ADDR    0x9100
#define C_ADDR    0x9200
#define DONE_ADDR 0x9300
#define DONE_MAGIC 0xDEADBEEFu

// -----------------------------------------------------------------------------
// NPU MMIO control/status registers (word offsets from MMIO_BASE)
// -----------------------------------------------------------------------------
#define MMIO_BASE 0x40000000u

#define CSR_CTRL    (*(volatile u32 *)(MMIO_BASE + 0x00))
#define CSR_STATUS  (*(volatile u32 *)(MMIO_BASE + 0x04))
#define CSR_DIM_M   (*(volatile u32 *)(MMIO_BASE + 0x08))
#define CSR_DIM_N   (*(volatile u32 *)(MMIO_BASE + 0x0C))
#define CSR_DIM_K   (*(volatile u32 *)(MMIO_BASE + 0x10))
#define CSR_A_BASE  (*(volatile u32 *)(MMIO_BASE + 0x14))
#define CSR_B_BASE  (*(volatile u32 *)(MMIO_BASE + 0x18))
#define CSR_C_BASE  (*(volatile u32 *)(MMIO_BASE + 0x1C))

#define CSR_START   0x1u
#define STATUS_DONE 0x2u

// -----------------------------------------------------------------------------
// Operands (INT8, row-major), linked at A_ADDR/B_ADDR by link.ld so the DMA can
// fetch them from DDR directly. Exercises K-tiling (K=8 vs NUM_ROWS=4) and
// N-tiling (N=6 vs NUM_COLS=4).
// -----------------------------------------------------------------------------
__attribute__((section(".a_buf")))
const i8 a_src[M * K] = {
     1,  2,  3,  4,  5,  6,  7,  8,
     8,  7,  6,  5,  4,  3,  2,  1
};

__attribute__((section(".b_buf")))
const i8 b_src[K * N] = {
     1,  2,  3,  4,  5,  6,
    -1, -2, -3, -4, -5, -6,
     1,  0,  1,  0,  1,  0,
     0,  1,  0,  1,  0,  1,
     2,  2,  2,  2,  2,  2,
    -2, -2, -2, -2, -2, -2,
     3,  3,  3,  3,  3,  3,
    -3, -3, -3, -3, -3, -3
};

// The operands must not be optimized away; the AXI4 DMA reads them straight
// from DDR at A_ADDR/B_ADDR (placement is fixed by link.ld and checked with
// riscv-none-elf-nm after linking).
__attribute__((noreturn))
void main(void)
{
    // 1. Program the NPU (dims + buffer bases). A/B already sit in DDR at the
    //    bases; the DMA fetches them autonomously.
    CSR_DIM_M  = M;
    CSR_DIM_N  = N;
    CSR_DIM_K  = K;
    CSR_A_BASE = A_ADDR;
    CSR_B_BASE = B_ADDR;
    CSR_C_BASE = C_ADDR;

    // 2. Launch and poll for completion.
    CSR_CTRL = CSR_START;
    while (!(CSR_STATUS & STATUS_DONE))
        ;

    // 3. Signal completion to the testbench (C was written back by the DMA).
    *(volatile u32 *)DONE_ADDR = DONE_MAGIC;

    for (;;)
        ;
}
