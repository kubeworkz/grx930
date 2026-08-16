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

// Cached-region AMO/LR/SC stress: four 64-bit scratch words in one dcache line
// (the dcache line is 32B here) plus a result magic the testbench polls.
#define AMO_BASE     0x9600   // 4 x 64-bit scratch words (one 32B cache line)
#define AMO_RES_ADDR 0x9470
#define AMO_PASS     0xC0FFEEu
#define AMO_FAIL     0xFEEDBEEFu

// Debug scratch: PHASE tracks program progress, DIAG holds the first failing
// stress step so the testbench can pinpoint the exact broken check.
#define PHASE_ADDR 0x9490
#define DIAG_ADDR  0x9480
#define FAIL_ADDR  0x94A0   // first failing stress step (C driver)

// Record the first failing stress step (only the first failure is kept).
#define CHECK(cond, step)                                        \
    do {                                                         \
        volatile u32 *_f = (volatile u32 *)FAIL_ADDR;            \
        if (!(cond) && *_f == 0)                                 \
            *_f = (step);                                        \
    } while (0)

#define DIAG(step)  (*diag = (step))

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
    volatile u32 *diag = (volatile u32 *)DIAG_ADDR;
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
    *diag = 0x601;
    mmio[2] = m;
    *diag = 0x602;
    mmio[3] = n;
    *diag = 0x603;
    mmio[4] = k;
    *diag = 0x604;
    mmio[5] = ab;
    *diag = 0x605;
    mmio[6] = bb;
    *diag = 0x606;
    mmio[7] = cb;

    // Read everything back and self-check.
    *diag = 0x607;
    if (mmio[2] != m)
        ok = 0;
    *diag = 0x608;
    if (mmio[3] != n)
        ok = 0;
    *diag = 0x609;
    if (mmio[4] != k)
        ok = 0;
    *diag = 0x60a;
    if (mmio[5] != ab)
        ok = 0;
    *diag = 0x60b;
    if (mmio[6] != bb)
        ok = 0;
    *diag = 0x60c;
    if (mmio[7] != cb)
        ok = 0;

    *diag = 0x700;
    *(volatile u32 *)STRESS_ADDR = ok ? STRESS_PASS : STRESS_FAIL;
    if (!ok)
        for (;;)
            ;   // hang so the testbench reports the failure
}

// -----------------------------------------------------------------------------
// Cached-region AMO/LR/SC stress. Exercises the dcache's AMO path
// (AMO_OP -> MEM_WRITE, write-through to DDR) and the LR/SC reservation
// protocol under back-to-back conditions on the SAME cache line:
//
//  (1) back-to-back AMO.D ops to one word (add/xor/or/and/min/max/swap),
//  (2) AMOs to a second word in the same line, with regular loads/stores
//      interleaved,
//  (3) LR.D -> SC.D success, and an SC.D with no outstanding LR (must fail),
//  (4) interleaved LR/SC pairs on the same line as the AMO traffic.
//
// The AMO ALU reads its rs2 operand from the store-data bus, so this also
// locks in the gate that keeps the store-data bus defined (memwrite||amo||sc).
// -----------------------------------------------------------------------------
static inline unsigned long long amo_add(volatile unsigned long long *p, unsigned long long v)
{
    unsigned long long old;
    __asm__ volatile("amoadd.d %0, %2, (%1)" : "=r"(old) : "r"(p), "r"(v) : "memory");
    return old;
}

static inline unsigned long long amo_xor(volatile unsigned long long *p, unsigned long long v)
{
    unsigned long long old;
    __asm__ volatile("amoxor.d %0, %2, (%1)" : "=r"(old) : "r"(p), "r"(v) : "memory");
    return old;
}

static inline unsigned long long amo_or(volatile unsigned long long *p, unsigned long long v)
{
    unsigned long long old;
    __asm__ volatile("amoor.d %0, %2, (%1)" : "=r"(old) : "r"(p), "r"(v) : "memory");
    return old;
}

static inline unsigned long long amo_and(volatile unsigned long long *p, unsigned long long v)
{
    unsigned long long old;
    __asm__ volatile("amoand.d %0, %2, (%1)" : "=r"(old) : "r"(p), "r"(v) : "memory");
    return old;
}

static inline unsigned long long amo_min(volatile unsigned long long *p, unsigned long long v)
{
    unsigned long long old;
    __asm__ volatile("amomin.d %0, %2, (%1)" : "=r"(old) : "r"(p), "r"(v) : "memory");
    return old;
}

static inline unsigned long long amo_max(volatile unsigned long long *p, unsigned long long v)
{
    unsigned long long old;
    __asm__ volatile("amomax.d %0, %2, (%1)" : "=r"(old) : "r"(p), "r"(v) : "memory");
    return old;
}

static inline unsigned long long amo_swap(volatile unsigned long long *p, unsigned long long v)
{
    unsigned long long old;
    __asm__ volatile("amoswap.d %0, %2, (%1)" : "=r"(old) : "r"(p), "r"(v) : "memory");
    return old;
}

static inline unsigned long long lr_d(volatile unsigned long long *p)
{
    unsigned long long v;
    __asm__ volatile("lr.d %0, (%1)" : "=r"(v) : "r"(p) : "memory");
    return v;
}

static inline unsigned long long sc_d(volatile unsigned long long *p, unsigned long long v)
{
    unsigned long long rc;
    __asm__ volatile("sc.d %0, %2, (%1)" : "=r"(rc) : "r"(p), "r"(v) : "memory");
    return rc;
}

static void dcache_stress(void)
{
    volatile unsigned long long *w = (volatile unsigned long long *)AMO_BASE;
    volatile u32 *diag = (volatile u32 *)DIAG_ADDR;
    volatile u32 *first_fail = (volatile u32 *)FAIL_ADDR;
    u32 ok = 1;

    // (1) Back-to-back AMO.D ops to w[0].
    *diag = 0x101;
    w[0] = 0x1000;
    if (amo_add(&w[0], 0x10) != 0x1000) { ok = 0; *first_fail = 0x101; } // -> 0x1010
    *diag = 0x102;
    if (amo_xor(&w[0], 0xFF) != 0x1010) { ok = 0; *first_fail = 0x102; } // -> 0x10EF
    *diag = 0x103;
    if (amo_or (&w[0], 0xF00) != 0x10EF) { ok = 0; *first_fail = 0x103; } // -> 0x1FEF
    *diag = 0x104;
    if (amo_and(&w[0], 0x1F00) != 0x1FEF) { ok = 0; *first_fail = 0x104; } // -> 0x1F00
    *diag = 0x105;
    if (amo_min(&w[0], 0x1000) != 0x1F00) { ok = 0; *first_fail = 0x105; } // -> 0x1000
    *diag = 0x106;
    if (amo_max(&w[0], 0x2000) != 0x1000) { ok = 0; *first_fail = 0x106; } // -> 0x2000
    *diag = 0x107;
    if (amo_swap(&w[0], 0xABCD) != 0x2000) { ok = 0; *first_fail = 0x107; } // -> 0xABCD
    *diag = 0x108;
    if (w[0] != 0xABCD) { ok = 0; *first_fail = 0x108; }

    // (2) Second word in the same line, interleaved with regular traffic.
    *diag = 0x201;
    w[1] = 0x1111;
    if (amo_add(&w[1], 0x1) != 0x1111) { ok = 0; *first_fail = 0x201; }    // -> 0x1112
    *diag = 0x202;
    w[1] = w[1] + 0x2;                             // regular store/load path
    *diag = 0x203;
    if (amo_xor(&w[1], 0xF0) != 0x1114) { ok = 0; *first_fail = 0x203; }    // -> 0x11E4
    *diag = 0x204;
    if (w[1] != 0x11E4) { ok = 0; *first_fail = 0x204; }

    // (3) LR/SC: success, then an SC with no outstanding LR (must fail).
    *diag = 0x301;
    w[2] = 0x7777;
    if (lr_d(&w[2]) != 0x7777) { ok = 0; *first_fail = 0x301; }
    *diag = 0x302;
    if (sc_d(&w[2], 0x8888) != 0) { ok = 0; *first_fail = 0x302; }          // success, rc = 0
    *diag = 0x303;
    if (w[2] != 0x8888) { ok = 0; *first_fail = 0x303; }
    *diag = 0x304;
    if (sc_d(&w[2], 0x9999) != 1) { ok = 0; *first_fail = 0x304; }          // no LR -> reservation miss
    *diag = 0x305;
    if (w[2] != 0x8888) { ok = 0; *first_fail = 0x305; }                    // write must not happen

    // (4) Interleaved LR/SC pairs on the same line as the AMO traffic.
    //     (Explicitly init w[3]: the TB reboots the core per sweep case, so
    //     DDR state carries over between boots and the LR must not assume 0.)
    w[3] = 0;
    *diag = 0x401;
    if (lr_d(&w[3]) != 0) { ok = 0; *first_fail = 0x401; }
    *diag = 0x402;
    if (sc_d(&w[3], 0x1234) != 0) { ok = 0; *first_fail = 0x402; }
    *diag = 0x403;
    if (lr_d(&w[3]) != 0x1234) { ok = 0; *first_fail = 0x403; }
    *diag = 0x404;
    if (sc_d(&w[3], 0x5678) != 0) { ok = 0; *first_fail = 0x404; }
    *diag = 0x405;
    if (w[3] != 0x5678) { ok = 0; *first_fail = 0x405; }

    *diag = 0x500;
    *(volatile u32 *)AMO_RES_ADDR = ok ? AMO_PASS : AMO_FAIL;
    if (!ok)
        for (;;)
            ;   // hang so the testbench reports the failure
}

__attribute__((noreturn))
void main(void)
{
    volatile u32 *phase = (volatile u32 *)PHASE_ADDR;
    volatile u32 *diag  = (volatile u32 *)DIAG_ADDR;

    // 0. Stress the cached-region AMO/LR/SC path (dcache AMO regression).
    *phase = 0x02;
    dcache_stress();
    *phase = 0x03;

    // 1. Stress the MMIO write/read-back path (regression coverage).
    mmio_stress();
    *phase = 0x05;

    // 1. Read the workload descriptor the testbench staged in DDR.
    u32 m = *(volatile u32 *)(DIMS_ADDR + 0x00);
    u32 n = *(volatile u32 *)(DIMS_ADDR + 0x04);
    u32 k = *(volatile u32 *)(DIMS_ADDR + 0x08);

    // 2. Program the NPU (dims + buffer bases). A/B already sit in DDR at the
    //    bases; the DMA fetches them autonomously.
    *phase = 0x06;
    CSR_DIM_M  = m;
    CSR_DIM_N  = n;
    CSR_DIM_K  = k;
    CSR_A_BASE = A_ADDR;
    CSR_B_BASE = B_ADDR;
    CSR_C_BASE = C_ADDR;

    // 3. Launch and poll for completion.
    *phase = 0x07;
    CSR_CTRL = CSR_START;
    while (!(CSR_STATUS & STATUS_DONE))
        ;

    // 4. Signal completion to the testbench (C was written back by the DMA).
    *phase = 0x08;
    *(volatile u32 *)DONE_ADDR = DONE_MAGIC;
    *phase = 0x09;

    for (;;)
        ;
}
