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
#define A_ADDR     0x8000   // 512-byte slot, above stack (grows down)
#define B_ADDR     0x8400   // 512-byte slot, avoids INT16 overlap with C
#define C_ADDR     0x8800   // 512-byte slot, avoids overlap with DIMS
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
#define CSR_PREC    (*(volatile u32 *)(MMIO_BASE + 0x20))
#define CSR_CYCLE   (*(volatile u32 *)(MMIO_BASE + 0x24))  // cycle count (read-only)
#define CSR_OP_CNT  (*(volatile u32 *)(MMIO_BASE + 0x2C))  // MAC op count (read-only)
#define CSR_STALL   (*(volatile u32 *)(MMIO_BASE + 0x30))  // stall count (read-only)

#define CSR_START   0x1u
#define STATUS_DONE 0x2u

// Precision modes (matching the CSR bit-field)
#define PREC_INT8   0u
#define PREC_INT16  1u
#define PREC_FP16   2u
#define PREC_BF16   3u
#define PREC_INT4   4u

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

// -----------------------------------------------------------------------------
// Store-ordering stress. Issues bursts of back-to-back stores and interleaves
// AMOs with regular stores to the SAME address, verifying program order:
//
//  (1) 16 back-to-back stores to one word must land in order, and after an
//      alias eviction the refill from DDR must show the last value (every
//      write-through landed),
//  (2) store -> AMO -> store -> AMO ... on the same word: each AMO must return
//      the value written by the preceding store (and the cache must have been
//      updated, not just DDR),
//  (3) AMO then store to the same word: the store must overwrite the AMO
//      result, and the evicted refill must show the store's value,
//  (4) a chain of 8 back-to-back AMOs to one word: each must see the previous
//      AMO's result (accumulating 1+2+...+8),
//  (5) back-to-back stores to all four words of the line, then verify all four
//      before and after an eviction (per-lane write-through integrity).
//
// STORE_BASE (index 0x44) and STORE_ALIAS (same index, different tag) force
// refills like the consistency stress. All words are explicitly initialized
// before use so the stress is idempotent across sweep boots.
// -----------------------------------------------------------------------------
#define STORE_BASE    0x9880   // 4 x 64-bit words in one 32B line (index 0x44)
#define STORE_ALIAS   0x1880   // alias: same index, different tag
#define STORE_RES_ADDR 0x94C0  // result magic (0x00FACADE = pass)
#define STORE_PASS    0x00FACADEu
#define STORE_FAIL    0xDEADFA11u

// Trap test: an illegal instruction traps to a real mtvec handler that records
// mcause, advances mepc past the fault, and mret's back. The handler lives in
// an icache line the fetch only ever enters via the trap redirect, so the trap
// setup lands during a line fill (regression coverage for the fetch-PC trap
// capture under stalls: a CSR redirect landing mid-fill must not be dropped).
#define TRAP_CNT_ADDR   0x94D0   // handler invocation counter
#define TRAP_CAUSE_ADDR 0x94D4   // mcause the handler observed, slot[cnt] (0x94D4 + 8*cnt)
#define TRAP_RES_ADDR   0x94D8   // result magic (0x00D0C1DE = pass)
#define TRAP_PASS       0x00D0C1DEu
#define TRAP_FAIL       0x0A11BADu

// Second-trap trigger (ecall) placed at 0x2020 by link.ld; see definition
// below trap_test. Forward-declared so trap_test can call it.
static void ecall_trigger(void);

// Forces the SC result to be read from the ARCHITECTED register (post-WB)
// instead of the combinational MEM->EX forward. The stranded-SC scenario needs
// to detect a dcache re-dispatch, which only corrupts the register file (rc
// flips 0 -> 1 on the cleared reservation); the forward stays correct.
__attribute__((noinline))
static int sc_rc_ok(unsigned long long rc)
{
    return (rc == 0) ? 1 : 0;
}

// Same idea for the LR: the stranded-LR scenario must verify the loaded value
// reached the architected register (post-WB), not just the forward used by the
// result-check branch.
__attribute__((noinline))
static int lr_val_ok(unsigned long long v)
{
    return (v == 0xABCDull) ? 1 : 0;
}

static void store_order_stress(void)
{
    volatile unsigned long long *s = (volatile unsigned long long *)STORE_BASE;
    volatile unsigned long long *al = (volatile unsigned long long *)STORE_ALIAS;
    volatile u32 *diag = (volatile u32 *)DIAG_ADDR;
    volatile u32 *first_fail = (volatile u32 *)FAIL_ADDR;
    u32 ok = 1;

    // (1) 16 back-to-back stores to one word, then verify cache + DDR.
    *diag = 0x901;
    s[0] = 0;
    for (int i = 1; i <= 16; i++)
        s[0] = i;
    if (s[0] != 16) { ok = 0; *first_fail = 0x901; }        // cache holds last store
    al[0] = 0xDEAD;                                         // evict s's line
    if (s[0] != 16) { ok = 0; *first_fail = 0x902; }        // refill from DDR: all 16 landed

    // (2) store -> AMO -> store -> AMO ... to the same word.
    *diag = 0x903;
    s[1] = 0x1000;
    if (amo_add(&s[1], 0x1) != 0x1000) { ok = 0; *first_fail = 0x903; }  // -> 0x1001
    s[1] = 0x2000;
    if (amo_add(&s[1], 0x1) != 0x2000) { ok = 0; *first_fail = 0x904; }  // -> 0x2001
    s[1] = 0x3000;
    if (amo_xor(&s[1], 0xF) != 0x3000) { ok = 0; *first_fail = 0x905; }  // -> 0x300F
    s[1] = 0x4000;
    if (amo_swap(&s[1], 0x5000) != 0x4000) { ok = 0; *first_fail = 0x906; }  // -> 0x5000
    if (s[1] != 0x5000) { ok = 0; *first_fail = 0x907; }

    // (3) AMO then store to the same word: the store must overwrite the result.
    *diag = 0x908;
    s[2] = 0x7777;
    if (amo_add(&s[2], 0x1) != 0x7777) { ok = 0; *first_fail = 0x908; }  // -> 0x7778
    s[2] = 0x8888;                                          // overwrite the AMO result
    if (s[2] != 0x8888) { ok = 0; *first_fail = 0x909; }
    al[1] = 0xEEEE;                                         // evict s's line
    if (s[2] != 0x8888) { ok = 0; *first_fail = 0x90A; }    // DDR has the store, not the AMO
    if (s[1] != 0x5000) { ok = 0; *first_fail = 0x90B; }    // neighbor word intact

    // (4) chain of 8 back-to-back AMOs to one word.
    *diag = 0x90C;
    unsigned long long expect = 0;
    s[3] = 0;
    for (int i = 1; i <= 8; i++) {
        if (amo_add(&s[3], i) != expect) { ok = 0; if (*first_fail == 0) *first_fail = 0x90C + i; }
        expect += i;
    }
    if (s[3] != 36) { ok = 0; if (*first_fail == 0) *first_fail = 0x915; }  // 1+2+...+8
    al[2] = 0xFFFF;                                         // evict s's line
    if (s[3] != 36) { ok = 0; if (*first_fail == 0) *first_fail = 0x916; }  // DDR has the sum

    // (5) back-to-back stores to all four words, then verify before/after eviction.
    *diag = 0x917;
    s[0] = 0xAAAA; s[1] = 0xBBBB; s[2] = 0xCCCC; s[3] = 0xDDDD;
    if (s[0] != 0xAAAA || s[1] != 0xBBBB || s[2] != 0xCCCC || s[3] != 0xDDDD)
        { ok = 0; *first_fail = 0x917; }
    al[3] = 0x1234;                                         // evict s's line
    if (s[0] != 0xAAAA || s[1] != 0xBBBB || s[2] != 0xCCCC || s[3] != 0xDDDD)
        { ok = 0; *first_fail = 0x918; }                    // all four landed in DDR

    // (6) LR/SC stranded across an icache-miss freeze. The SC's success branch
    //     redirects to an icache line the fetch only ever enters via this
    //     branch; the line fill freezes the pipeline while the SC sits in MEM.
    //     The dcache must not re-dispatch the completed SC - a re-dispatch
    //     sees the cleared reservation, reports rc=1, and corrupts the SC's
    //     architected register result (the memory write-through stays correct).
    *diag = 0x921;
    volatile unsigned long long *fx = (volatile unsigned long long *)(STORE_BASE + 0x20);
    unsigned long long frc;
    fx[0] = 0;
    lr_d(fx);
    frc = sc_d(fx, 0x5151ull);
    if (frc == 0)
        goto sc_freeze_done;
    // Fail path - never taken in the pass case. Padded with a small volatile
    // loop so sc_freeze_done lands in a line the fetch has not yet reached
    // when the success branch above resolves (the strand needs the miss).
    {
        volatile u32 pad = 0;
        for (int p = 0; p < 8; p++)
            pad += p;
        if (pad)
            *first_fail = 0x921;
        ok = 0;
    }
sc_freeze_done:
    if (!sc_rc_ok(frc)) { ok = 0; if (*first_fail == 0) *first_fail = 0x922; }
    if (fx[0] != 0x5151ull) { ok = 0; if (*first_fail == 0) *first_fail = 0x923; }
    al[4] = 0xEEEE;                                         // evict fx's line
    if (fx[0] != 0x5151ull) { ok = 0; if (*first_fail == 0) *first_fail = 0x924; }  // DDR

    // (7) stranded LR: the LR's result-check branch redirects to an icache
    //     line the fetch only ever enters via this branch, so the line fill
    //     freezes the pipeline while the LR sits in MEM. The loaded value must
    //     still reach the architected register (post-WB) and the reservation
    //     must survive the freeze so a subsequent SC still succeeds.
    *diag = 0x931;
    volatile unsigned long long *gx = (volatile unsigned long long *)(STORE_BASE + 0x20);
    unsigned long long glr;
    gx[0] = 0xABCDull;
    glr = lr_d(gx);
    if (glr == 0xABCDull)
        goto lr_freeze_done;
    // Fail path - never taken in the pass case; padded so lr_freeze_done lands
    // in a line the fetch has not yet reached when the result branch resolves.
    {
        volatile u32 pad = 0;
        for (int p = 0; p < 8; p++)
            pad += p;
        if (pad)
            *first_fail = 0x931;
        ok = 0;
    }
lr_freeze_done:
    if (!lr_val_ok(glr)) { ok = 0; if (*first_fail == 0) *first_fail = 0x932; }
    if (sc_d(gx, 0xBEEF) != 0) { ok = 0; if (*first_fail == 0) *first_fail = 0x933; }  // reservation survived
    if (gx[0] != 0xBEEF) { ok = 0; if (*first_fail == 0) *first_fail = 0x934; }
    al[4] = 0xEEEE;                                         // evict gx's line
    if (gx[0] != 0xBEEF) { ok = 0; if (*first_fail == 0) *first_fail = 0x935; }  // DDR

    *diag = 0x920;
    *(volatile u32 *)STORE_RES_ADDR = ok ? STORE_PASS : STORE_FAIL;
    if (!ok)
        for (;;)
            ;   // hang so the testbench reports the failure
}

// -----------------------------------------------------------------------------
// Trap test: illegal instruction -> real mtvec handler -> mret, exactly once.
//
// The handler is compiled as a separate noinline function placed after this
// test in the .text output, so its icache line is only ever entered via the
// trap redirect: the redirect misses, the line fill freezes the pipeline while
// the CSR unit's trap setup (pc_cntrl_wb / setting_up) is active, and the
// fetch-PC register must capture the handler address DURING the stall. If the
// trap redirect is dropped (the pre-fix behavior), execution falls through to
// the checks below with the handler never having run (cnt stays 0).
// -----------------------------------------------------------------------------
// The whole handler is one deterministic asm blob. Why: a C handler's
// restore epilogue (ld ra; ret) lands AFTER the mret and is dead code, so ra
// would stay clobbered by the handler's own jals and the interrupted code's
// ret would jump into the handler body (re-running the mret without a trap
// setup, which corrupts the CSR state machine). The blob below explicitly
// preserves the registers trap_test lives on across the trap (a5 = &DIAG,
// a3 = &CNT, ra = 0x12d0, sp) and restores them BEFORE the mret.
//
// CSR encodings (no Zicsr in the march string):
//   0x342022F3  csrrs t0, mcause, x0
//   0x341022F3  csrrs t0, mepc,   x0
//   0x34129073  csrrw x0, mepc,   t0   (mepc += 4 to skip the faulting instr)
//   0x30200073  mret
__attribute__((noinline)) static void trap_handler(void)
{
    asm volatile(
        "addi  sp, sp, -32\n\t"
        "sd    ra, 24(sp)\n\t"
        "sd    a3, 16(sp)\n\t"
        "sd    a5,  8(sp)\n\t"
        // *slot = mcause, where slot = 0x94D4 + 8*cnt (cnt BEFORE increment),
        // so each invocation records its own cause and the first (illegal =
        // 2) isn't overwritten by the second (ecall = 11). Only t0/t1/a5 are
        // clobbered (the same set the original handler used).
        "lui   a5, 0x9\n\t"
        "lw    t1, 0x4d0(a5)\n\t"          // t1 = cnt (pre-increment)
        "slli  t1, t1, 3\n\t"              // t1 = cnt*8
        "addi  a5, a5, 0x4d4\n\t"          // a5 = 0x94D4
        "add   a5, a5, t1\n\t"             // a5 = slot
        ".word 0x342022F3\n\t"            // csrrs t0, mcause, x0
        "sw    t0, 0(a5)\n\t"              // *slot = mcause
        // mepc += 4 (skip the faulting instruction)
        ".word 0x341022F3\n\t"
        "addi  t0, t0, 4\n\t"
        ".word 0x34129073\n\t"
        // cnt += 1
        "lui   a5, 0x9\n\t"
        "lw    t1, 0x4d0(a5)\n\t"
        "addiw t1, t1, 1\n\t"
        "sw    t1, 0x4d0(a5)\n\t"
        // restore the interrupted context, THEN mret
        "ld    a5,  8(sp)\n\t"
        "ld    a3, 16(sp)\n\t"
        "ld    ra, 24(sp)\n\t"
        "addi  sp, sp, 32\n\t"
        ".word 0x30200073\n\t"
    );
}

__attribute__((noinline))
static void trap_test(void)
{
    volatile u32 *cnt  = (volatile u32 *)TRAP_CNT_ADDR;
    volatile u32 *caus = (volatile u32 *)TRAP_CAUSE_ADDR;
    volatile u32 *diag = (volatile u32 *)DIAG_ADDR;
    volatile u32 *first_fail = (volatile u32 *)FAIL_ADDR;
    u32 ok = 1;
    register unsigned long long t0 asm("t0");

    *diag = 0x941;
    *cnt = 0;
    *caus = 0;

    // Install the handler: csrrw x0, mtvec, t0.
    t0 = (unsigned long long)(unsigned long)trap_handler;
    asm volatile(".word 0x30529073" :: "r"(t0));

    // Trigger the illegal instruction (opcode 0x0B - custom-0, not decoded).
    // On success the handler mret's back to the instruction after this one;
    // on a dropped redirect (the bug under test) the fetch falls through to
    // the checks below instead and the count stays 0.
    *diag = 0x942;
    asm volatile(".word 0x0000000B");

    // Handler must have run exactly once, seen the illegal-instruction cause
    // (mcause == 2), and mret'd back to here.
    *diag = 0x943;
    if (*cnt != 1) { ok = 0; if (*first_fail == 0) *first_fail = 0x943; }
    if (*caus != 2) { ok = 0; if (*first_fail == 0) *first_fail = 0x944; }

    // Second trap: an ecall (mcause = 11) fired from code whose icache line
    // aliases the handler's (0x2020 has index 1, tag 2; the handler at 0x24
    // has index 1, tag 0), so calling it EVICTS the cached handler line and
    // the redirect to 0x24 must miss again -> the handler re-enters from a
    // cold line, exercising the same stall/redirect path as the first trap.
    *diag = 0x945;
    ecall_trigger();

    // Now the handler must have run exactly twice, with the first invocation
    // still recorded as mcause==2 and the second as mcause==11 (the slot
    // indexing in the handler must not have overwritten the first cause).
    *diag = 0x946;
    if (*cnt != 2) { ok = 0; if (*first_fail == 0) *first_fail = 0x946; }
    if (*caus != 2) { ok = 0; if (*first_fail == 0) *first_fail = 0x947; }
    if (*(volatile u32 *)(TRAP_CAUSE_ADDR + 8) != 11) { ok = 0; if (*first_fail == 0) *first_fail = 0x948; }

    // Defensive: restore mtvec = 0 (nothing traps after this point).
    t0 = 0;
    asm volatile(".word 0x30529073" :: "r"(t0));

    *diag = 0x940;
    *(volatile u32 *)TRAP_RES_ADDR = ok ? TRAP_PASS : TRAP_FAIL;
    if (!ok)
        for (;;)
            ;   // hang so the testbench reports the failure
}

// -----------------------------------------------------------------------------
// Second-trap trigger: an ecall (mcause = 11) fired from a fixed address that
// aliases the handler's icache line. link.ld places this section at 0x2020:
// icache index = addr[11:5] = 1 (same line as the handler at 0x24) but tag =
// addr[63:12] = 2 (the handler's tag is 0), so merely CALLING this function
// refills line 1 with a different tag and evicts the cached handler bytes.
// The ecall then traps and the redirect to 0x24 misses again -> the handler
// is re-entered from a cold line under a cache-fill stall.
// -----------------------------------------------------------------------------
__attribute__((section(".ecall_trig"), noinline, used))
static void ecall_trigger(void)
{
    asm volatile(
        ".word 0x00000073\n\t"   // ecall -> mcause = 11
        "ret\n\t"                // mret returns here (mepc+4), then back to caller
    );
}

// -----------------------------------------------------------------------------
// Performance benchmark. Runs large GEMMs across INT4/INT8/INT16/FP16/BF16 and
// reports throughput (TOPS), cycle count, op count, and stall ratio.
//
// Each precision gets a representative GEMM: M=8 N=8 K=16 (2 K-tiles for
// double-buffer exercise). Results are written to DDR for the testbench to
// display.
//
// PERF_RES_ADDR layout (per case, 6 words = 24 bytes, 5 cases = 120 bytes):
//   +0x00: cycles   +0x04: ops   +0x08: stalls
//   +0x0C: tops_mhz (TOPS * 1000, integer)   +0x10: stall_pct (stalls/cycles * 100)
//   +0x14: reserved
// -----------------------------------------------------------------------------
#define PERF_RES_ADDR 0x9500

// NPU clock frequency in Hz (50 MHz on Arty A7 with CLK_DIV=2).
// For simulation, cycles are absolute so TOPS = ops / cycles * clock_freq.
#define NPU_CLK_HZ  50000000ull

__attribute__((noinline))
static void run_perf_case(int m, int n, int k, int prec, int case_idx)
{
    volatile u32 *res = (volatile u32 *)(PERF_RES_ADDR + case_idx * 24);
    volatile u32 *diag = (volatile u32 *)DIAG_ADDR;

    *diag = 0xB00 + case_idx;
    CSR_DIM_M  = m;
    CSR_DIM_N  = n;
    CSR_DIM_K  = k;
    CSR_A_BASE = A_ADDR;
    CSR_B_BASE = B_ADDR;
    CSR_C_BASE = C_ADDR;
    CSR_PREC   = prec;
    {volatile u32 _b; _b = CSR_PREC; (void)_b;}

    // Reset counters by reading (counters reset on START)
    CSR_CTRL = CSR_START;
    while (!(CSR_STATUS & STATUS_DONE))
        ;

    // Read performance counters (snapshot after completion)
    unsigned long cycles = CSR_CYCLE;
    unsigned long ops    = CSR_OP_CNT;
    unsigned long stalls = CSR_STALL;

    // Compute TOPS: 2*M*N*K MACs per GEMM, TOPS = ops / cycles * clk_freq
    // We store TOPS * 1000 as integer for display
    unsigned long macs = 2ull * m * n * k;
    unsigned long tops_x1000 = 0;
    if (cycles > 0)
        tops_x1000 = (macs * NPU_CLK_HZ) / (cycles * 1000000ull);

    unsigned long stall_pct = 0;
    if (cycles > 0)
        stall_pct = (stalls * 100) / cycles;

    res[0] = cycles;
    res[1] = ops;
    res[2] = stalls;
    res[3] = tops_x1000;
    res[4] = stall_pct;
    res[5] = 0;  // reserved
}

__attribute__((noinline))
static void perf_bench(void)
{
    volatile u32 *diag = (volatile u32 *)DIAG_ADDR;

    *diag = 0xB00;
    // INT4: M=8 N=8 K=16 (2 K-tiles, double-buffer exercised)
    run_perf_case(8, 8, 16, 4, 0);
    // INT8: M=8 N=8 K=16
    run_perf_case(8, 8, 16, 0, 1);
    // INT16: M=8 N=8 K=16
    run_perf_case(8, 8, 16, 1, 2);
    // FP16: M=8 N=8 K=16
    run_perf_case(8, 8, 16, 2, 3);
    // BF16: M=8 N=8 K=16
    run_perf_case(8, 8, 16, 3, 4);

    *diag = 0xBFF;
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

    // 0c. Store-ordering stress (back-to-back stores + AMO/store interleave).
    store_order_stress();
    *phase = 0x04;

    // 1. Stress the MMIO write/read-back path (regression coverage).
    mmio_stress();
    *phase = 0x05;

    // 1b. Trap test: real mtvec handler + mret under a cache-fill stall.
    *phase = 0x0A;
    trap_test();
    *phase = 0x0B;

    // 1. Read the workload descriptor the testbench staged in DDR.
    u32 m = *(volatile u32 *)(DIMS_ADDR + 0x00);
    u32 n = *(volatile u32 *)(DIMS_ADDR + 0x04);
    u32 k = *(volatile u32 *)(DIMS_ADDR + 0x08);
    u32 prec = *(volatile u32 *)(DIMS_ADDR + 0x0C);  // precision: 0=INT8, 1=INT16

    // 2. Program the NPU (dims + buffer bases + precision). A/B already sit in
    //    DDR at the bases; the DMA fetches them autonomously.
    *phase = 0x06;
    CSR_DIM_M  = m;
    CSR_DIM_N  = n;
    CSR_DIM_K  = k;
    CSR_A_BASE = A_ADDR;
    CSR_B_BASE = B_ADDR;
    CSR_C_BASE = C_ADDR;
    CSR_PREC   = prec;
    // Read-back barrier: ensures the PREC MMIO write completes (through the
    // bridge's AXI handshake) before the START pulse is issued.
    {volatile u32 _b; _b = CSR_PREC; (void)_b;}

    // 3. Launch and poll for completion.
    *phase = 0x07;
    CSR_CTRL = CSR_START;
    while (!(CSR_STATUS & STATUS_DONE))
        ;

    // 4. Signal completion to the testbench (C was written back by the DMA).
    *phase = 0x08;
    *(volatile u32 *)DONE_ADDR = DONE_MAGIC;
    *phase = 0x09;

    // 5. Run performance benchmark across precisions (AFTER done signal so
    //    the testbench captures C before we overwrite the buffers).
    *phase = 0x10;
    perf_bench();
    *phase = 0x11;

    for (;;)
        ;
}
