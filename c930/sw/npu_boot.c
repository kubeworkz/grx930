// -----------------------------------------------------------------------------
// npu_boot.c - tiny NPU GEMM kick-off firmware for the SYNTH DDR stub.
//
// The synth-only c930_ddr stub is a 512-byte boot memory (16 lines x 32 B).
// This program must therefore fit its code + operands inside that window and
// hardcode the workload: no testbench staging, no dims descriptor.
//
// It programs a fixed 2x4x2 INT8 GEMM over MMIO, starts the NPU, and spins on
// STATUS.DONE. The operands live in .ops_a/.ops_b (placed by link_boot.ld at
// 0x100/0x110 inside the stub window); the NPU DMA fetches them and writes the
// 2x2 INT32 C result to 0x120.
//
// Expected C (row-major A[MxK] x B[KxN]):
//   A = [1 2 3 4]   B = [1 0]        C = [1 2]
//       [5 6 7 8]       [0 1]            [5 6]
//                       [0 0]
//                       [0 0]
// On the Arty board this lights o_npu_busy (LD4) for the GEMM duration, then
// o_npu_done/o_npu_irq (LD5/LD7) pulse on completion.
// -----------------------------------------------------------------------------

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

#define CSR_START   0x1u
#define STATUS_DONE 0x2u

// Byte addresses inside the 512-byte stub window.
#define A_ADDR 0x100u
#define B_ADDR 0x110u
#define C_ADDR 0x120u

// -----------------------------------------------------------------------------
// Operands. link_boot.ld pins .ops_a at 0x100 and .ops_b at 0x110 inside the
// stub window (both inside line 8), clear of the code (lines 0..~3).
// -----------------------------------------------------------------------------
__attribute__((section(".ops_a"), used))
const signed char A_ops[8] = { 1,  2,  3,  4,  5,  6,  7,  8 };

__attribute__((section(".ops_b"), used))
const signed char B_ops[8] = { 1,  0,  0,  1,  0,  0,  0,  0 };

void main(void)
{
    CSR_DIM_M  = 2;
    CSR_DIM_N  = 2;
    CSR_DIM_K  = 4;
    CSR_A_BASE = A_ADDR;
    CSR_B_BASE = B_ADDR;
    CSR_C_BASE = C_ADDR;
    CSR_CTRL   = CSR_START;

    while (!(CSR_STATUS & STATUS_DONE))
        ;

    for (;;)
        ;
}
