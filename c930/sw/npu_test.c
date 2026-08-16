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

// -----------------------------------------------------------------------------
// Multi-line memory-consistency stress. Interleaves AMOs and regular
// loads/stores across FOUR dcache lines, plus same-index/different-tag ALIAS
// lines, so the refill path (write-through integrity) is exercised:
//
//  (1) per line: init store, AMO, cache read-back, alias eviction, then a
//      re-read that MUST refill from DDR and see the AMO-updated value
//      (catches a write-through that only hit the cache, or a fill that
//      returns a stale block),
//  (2) same-line word independence: a store and an AMO to different words of
//      one line must not disturb each other,
//  (3) cross-line interleave: AMO/load/store traffic on two resident lines
//      with per-step checks (catches tag/index contamination),
//  (4) LR/SC with a line eviction between LR and SC: the reservation must
//      survive the refill and the SC must still succeed,
//  (5) double eviction: AMO a line and its alias, touch unrelated traffic,
//      then re-read both - each must refill from DDR with its own value.
//
// The dcache is direct-mapped (32B lines, index addr[11:5]); within 64KB,
// CONS_BASE and CONS_ALIAS share an index but differ in bits[15:12], so every
// cross-access evicts the other line and forces a refill. All scratch words
// are explicitly initialized before use so the stress is idempotent across
// sweep boots (the TB reboots the core per case and DDR state carries over).
// -----------------------------------------------------------------------------
#define CONS_BASE     0x9800   // 4 x 32B lines (indices 0x40..0x43)
#define CONS_ALIAS    0x1800   // aliases: same index, different tag
#define CONS_RES_ADDR 0x94B0   // result magic (0x5EEDCAFE = pass)
#define CONS_PASS     0x5EEDCAFEu
#define CONS_FAIL     0xDEADF00Du

static void mem_consistency_stress(void)
{
    volatile unsigned long long *L[4], *A[4];
    volatile u32 *diag = (volatile u32 *)DIAG_ADDR;
    volatile u32 *first_fail = (volatile u32 *)FAIL_ADDR;
    u32 ok = 1;

    for (int i = 0; i < 4; i++) {
        L[i] = (volatile unsigned long long *)(CONS_BASE  + 0x20*i);
        A[i] = (volatile unsigned long long *)(CONS_ALIAS + 0x20*i);
    }

    // (1) init store, AMO, cache read-back, alias eviction, DDR re-read.
    for (int i = 0; i < 4; i++) {
        *diag = 0x801 + i;
        L[i][0] = 0x1000ull + i;                        // cold line: fill + write-through
        if (amo_add(&L[i][0], 0x11) != (0x1000ull + i)) { ok = 0; *first_fail = 0x801 + i; }
        if (L[i][0] != (0x1011ull + i)) { ok = 0; *first_fail = 0x802 + i; }  // cache hit
        A[i][0] = 0x2000ull + i;                        // alias store evicts L[i]
        if (L[i][0] != (0x1011ull + i)) { ok = 0; *first_fail = 0x803 + i; }  // refill from DDR
    }

    // (2) same-line word independence: store to word0, AMO to word1.
    *diag = 0x810;
    L[0][1] = 0x9999;
    L[0][0] = 0x1111;
    if (L[0][0] != 0x1111) { ok = 0; *first_fail = 0x810; }
    if (amo_swap(&L[0][1], 0x2222) != 0x9999) { ok = 0; *first_fail = 0x811; }
    if (L[0][0] != 0x1111) { ok = 0; *first_fail = 0x812; }   // AMO must not touch word0
    if (L[0][1] != 0x2222) { ok = 0; *first_fail = 0x813; }

    // (3) cross-line interleave on two resident lines.
    *diag = 0x820;
    L[1][0] = 0x3000;
    L[2][0] = 0x4000;
    if (amo_add(&L[1][0], 0x1) != 0x3000) { ok = 0; *first_fail = 0x820; }
    if (L[2][0] != 0x4000) { ok = 0; *first_fail = 0x821; }   // L2 intact after AMO to L1
    if (amo_xor(&L[2][0], 0x0F) != 0x4000) { ok = 0; *first_fail = 0x822; }
    if (L[1][0] != 0x3001) { ok = 0; *first_fail = 0x823; }   // L1 intact after AMO to L2
    L[2][0] = L[2][0] + 1;                                    // regular store/load path
    if (L[1][0] != 0x3001) { ok = 0; *first_fail = 0x824; }
    if (L[2][0] != 0x4010) { ok = 0; *first_fail = 0x825; }   // 0x400F + 1

    // (4) LR/SC across a line eviction: reservation must survive the refill.
    *diag = 0x830;
    L[3][0] = 0x5000;
    if (lr_d(&L[3][0]) != 0x5000) { ok = 0; *first_fail = 0x830; }
    A[3][0] = 0x6000;                       // evicts L[3] (same index, different tag)
    if (sc_d(&L[3][0], 0x5555) != 0) { ok = 0; *first_fail = 0x831; }  // SC must succeed
    if (L[3][0] != 0x5555) { ok = 0; *first_fail = 0x832; }

    // (5) double eviction: AMO a line and its alias, unrelated traffic, re-read both.
    *diag = 0x840;
    L[2][1] = 0x7000;
    A[2][0] = 0x8000;
    if (amo_add(&L[2][1], 0x1) != 0x7000) { ok = 0; *first_fail = 0x840; }  // evicts A[2]
    if (amo_add(&A[2][0], 0x1) != 0x8000) { ok = 0; *first_fail = 0x841; }  // evicts L[2]
    L[1][1] = 0x9000;                       // unrelated traffic
    if (L[2][1] != 0x7001) { ok = 0; *first_fail = 0x842; }  // refill from DDR
    if (A[2][0] != 0x8001) { ok = 0; *first_fail = 0x843; }  // refill from DDR

    *diag = 0x850;
    *(volatile u32 *)CONS_RES_ADDR = ok ? CONS_PASS : CONS_FAIL;
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

    // 0b. Multi-line memory-consistency stress (write-through/eviction/refill).
    mem_consistency_stress();
    *phase = 0x04;

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
