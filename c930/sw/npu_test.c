// -----------------------------------------------------------------------------
// npu_test.c - bare-metal workload runner for the C930 NPU.
//
// Runs on the RV64IMAC core (no libc, no OS). The testbench preloads the INT8
// A (MxK) and B (KxN) operands into DDR at the fixed buffer bases and writes a
// 3-word workload descriptor (M, N, K) to DIMS_ADDR before booting the core.
// This driver performs NO data staging: it reads the dims from DDR, programs
// the NPU over MMIO, and the NPU's AXI4 DMA fetches A/B from DDR, runs the
// GEMM, and burst-writes C back. The driver then polls STATUS.DONE and writes
// a completion magic the testbench polls.
//
// GEMM: C[MxN] = A[MxK] x B[KxN], INT8 inputs, INT32 outputs.
// -----------------------------------------------------------------------------

typedef unsigned int u32;

// -----------------------------------------------------------------------------
// DDR workload layout (byte addresses, written by the testbench before boot)
// -----------------------------------------------------------------------------
#define A_ADDR     0x9000
#define B_ADDR     0x9100
#define C_ADDR     0x9200
#define DIMS_ADDR  0x9400
#define DONE_ADDR  0x9410
#define DONE_MAGIC 0xDEADBEEFu
#define STRESS_ADDR 0x9420
#define STRESS_PASS 0x0BADBEEFu
#define STRESS_FAIL 0xBADF00Du

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
// MMIO stress. Regression coverage for two reference-core bugs that corrupted
// the NPU's register programming:
//
//  (1) store-data forward dropping: when a producer (li/lui feeding a store's
//      data) leaves WB while a back-to-back MMIO store ahead of it stalls in
//      MEM, the WB->EX forward collapses and the queued store latches a stale
//      pre-write value (fixed by freezing WB during dcache/MMIO stalls);
//  (2) back-to-back MMIO stores losing or corrupting writes.
//
// Writes distinctive values (derived from the volatile dims descriptor so the
// producers cannot be hoisted away) to every writable NPU register, reads
// them all back over MMIO, and records a pass/fail magic for the testbench.
// -----------------------------------------------------------------------------
static void mmio_stress(void)
{
    volatile u32 *mmio = (volatile u32 *)MMIO_BASE;
    u32 ok = 1;

    // Values are produced 1-3 instructions before their stores (xor/addi on
    // volatile-loaded operands), so the store data must come from the forward
    // path rather than the register file.
    u32 m  = (*(volatile u32 *)(DIMS_ADDR + 0x00) & 0xFFFFu) ^ 0xBEEFu;
    u32 n  = (*(volatile u32 *)(DIMS_ADDR + 0x04) & 0xFFFFu) ^ 0x0BADu;
    u32 k  = (*(volatile u32 *)(DIMS_ADDR + 0x08) & 0xFFFFu) ^ 0xF00Du;
    u32 ab = (*(volatile u32 *)(DIMS_ADDR + 0x00) << 16) | 0xABCDu;
    u32 bb = (*(volatile u32 *)(DIMS_ADDR + 0x04) << 16) | 0xEF01u;
    u32 cb = (*(volatile u32 *)(DIMS_ADDR + 0x08) << 16) | 0x2345u;

    // Back-to-back MMIO stores; each stalls the MEM stage for several cycles.
    mmio[2] = m;
    mmio[3] = n;
    mmio[4] = k;
    mmio[5] = ab;
    mmio[6] = bb;
    mmio[7] = cb;

    // Read everything back and self-check.
    if (mmio[2] != m)
        ok = 0;
    if (mmio[3] != n)
        ok = 0;
    if (mmio[4] != k)
        ok = 0;
    if (mmio[5] != ab)
        ok = 0;
    if (mmio[6] != bb)
        ok = 0;
    if (mmio[7] != cb)
        ok = 0;

    *(volatile u32 *)STRESS_ADDR = ok ? STRESS_PASS : STRESS_FAIL;
    if (!ok)
        for (;;)
            ;   // hang so the testbench reports the failure
}

__attribute__((noreturn))
void main(void)
{
    // 0. Stress the MMIO write/read-back path (regression coverage).
    mmio_stress();

    // 1. Read the workload descriptor the testbench staged in DDR.
    u32 m = *(volatile u32 *)(DIMS_ADDR + 0x00);
    u32 n = *(volatile u32 *)(DIMS_ADDR + 0x04);
    u32 k = *(volatile u32 *)(DIMS_ADDR + 0x08);

    // 2. Program the NPU (dims + buffer bases). A/B already sit in DDR at the
    //    bases; the DMA fetches them autonomously.
    CSR_DIM_M  = m;
    CSR_DIM_N  = n;
    CSR_DIM_K  = k;
    CSR_A_BASE = A_ADDR;
    CSR_B_BASE = B_ADDR;
    CSR_C_BASE = C_ADDR;

    // 3. Launch and poll for completion.
    CSR_CTRL = CSR_START;
    while (!(CSR_STATUS & STATUS_DONE))
        ;

    // 4. Signal completion to the testbench (C was written back by the DMA).
    *(volatile u32 *)DONE_ADDR = DONE_MAGIC;

    for (;;)
        ;
}
