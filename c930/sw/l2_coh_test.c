// ---------------------------------------------------------------------------
// l2_coh_test.c -- the L2 directory's blind spot, as firmware meets it.
//
// c930_l2.sv records a sharer on a read fill.  A write is write-through with no
// allocate: the L2 invalidates the sharers it knows of EXCEPT the writer (which
// has the new data in its L1), then drops its own copy of the line -- valid and
// sharers both cleared.  So after a CPU writes a line, the L2 no longer records
// that the CPU holds it.  A later write by anyone else finds the line not
// resident, computes an empty invalidation mask, and invalidates nobody.  The
// CPU's L1 keeps its stale copy for as long as the line survives.
//
// That is how C4(a) lost its firmware half.  A driver that cleared C before a
// GEMM and read C after it read back its own zeros -- so an impaired GEMM looked
// right (C all zero) and an exact one looked wrong (C zero, not K), which is the
// worse way round.  The workaround since has been a rule: firmware must not write
// a buffer the accelerator writes.  Two firmwares now carry it in comments
// (pta_test.c dropped its clear_c; pta_sweep.c gives every point its own C and
// never clears one), and a rule that lives only in comments is a trap for the
// next person.
//
// This is that trap, made into a test.
//
//   T1  the bug itself.  The CPU poisons C, the DMA overwrites it, the CPU reads
//       it back.  With a directory that forgets the writer, the read returns the
//       poison.  With one that does not, it returns the GEMM's answer.
//   T2  the control: the same GEMM with C never touched by the CPU, which is the
//       path every working firmware takes today.  If T2 fails the problem is not
//       coherence and this test says so instead of blaming the directory.
//   T3  a line the CPU only READ before the DMA wrote it.  A read fill records
//       the sharer, so the directory knows about this one and should invalidate
//       it.  T3 passing while T1 fails is the diagnosis: the directory works, it
//       just loses the entry on a write.
//
// Every operand is 1, so every C element is exactly K.
//
// DDR map:
//   0x9400 : M, N, K, precision       0x9410 : DONE magic
//   0x9420 : RESULT (PASS/FAIL)       0x9430 : recorded values
//   0x9480 : DIAG (a bit per check)   0x9490 : PHASE
// ---------------------------------------------------------------------------
#include "c930_npu_driver.h"

typedef unsigned int u32;

#define A_ADDR      0x1000u
#define B_ADDR      0x2000u
// Three C blocks, one per check, so no check reads a line an earlier one pulled
// into the L1 -- that would hide or fake the very effect being measured.
#define C1_ADDR     0x3000u
#define C2_ADDR     0x3400u
#define C3_ADDR     0x3800u
#define DIMS_ADDR   0x9400u
#define DONE_ADDR   0x9410u
#define RESULT_ADDR 0x9420u
#define REC_ADDR    0x9430u
#define DIAG_ADDR   0x9480u
#define PHASE_ADDR  0x9490u

#define DONE_MAGIC  0xDEADBEEFu
#define PASS_MAGIC  0x0BADBEEFu
#define FAIL_MAGIC  0x0BADF00Du

#define T1_OK       0x001u   /* the CPU-written line is invalidated */
#define T2_OK       0x002u   /* the control: an untouched C reads back right */
#define T3_OK       0x004u   /* a CPU-read line is invalidated */

#define POISON      0x0BADC0DEu

static u32  rd(u32 a)        { return *(volatile u32 *)a; }
static void wr(u32 a, u32 v) { *(volatile u32 *)a = v; }
static void rec(int i, u32 v) { wr(REC_ADDR + 4u * (u32)i, v); }

static int run_gemm(int m, int n, int k, u32 c_base)
{
    npu_drv_gemm_t g;
    g.dim_m = (u32)m; g.dim_n = (u32)n; g.dim_k = (u32)k;
    g.a_base = A_ADDR; g.b_base = B_ADDR; g.c_base = c_base;
    g.prec = NPU_PREC_INT8;
    if (npu_drv_submit(&g) != 0)
        return 0;
    if (npu_drv_drain(4000000ull) != 0)
        return 0;
    return npu_drv_error() ? 0 : 1;
}

// How many of C's elements read back as the GEMM's answer, and what the first
// wrong one held -- the value says which failure this is.  Poison means the CPU
// kept its own line; anything else means the GEMM itself is wrong.
static int c_check(u32 base, int m, int n, int k, u32 *first_bad)
{
    int i, good = 0;
    *first_bad = 0xFFFFFFFFu;
    for (i = 0; i < m * n; i++) {
        const u32 v = rd(base + 4u * (u32)i);
        if (v == (u32)k)
            good++;
        else if (*first_bad == 0xFFFFFFFFu)
            *first_bad = v;
    }
    return good;
}

int main(void)
{
    int m, n, k, i, good;
    u32 diag = 0, bad;

    wr(DONE_ADDR, 0);
    wr(RESULT_ADDR, 0);
    wr(DIAG_ADDR, 0);
    wr(PHASE_ADDR, 1);

    m = (int)rd(DIMS_ADDR + 0);
    n = (int)rd(DIMS_ADDR + 4);
    k = (int)rd(DIMS_ADDR + 8);

    npu_drv_mmio(NPU0_BASE);

    /* ---- T2 first: the control ---------------------------------------------
     * The path every working firmware takes -- C is never touched by the CPU
     * before the GEMM.  Run it first so that if the machine is broken in some
     * unrelated way, the report says so before accusing the directory. */
    wr(PHASE_ADDR, 2);
    if (run_gemm(m, n, k, C2_ADDR)) {
        good = c_check(C2_ADDR, m, n, k, &bad);
        rec(4, (u32)good);
        rec(5, bad);
        if (good == m * n)
            diag |= T2_OK;
    }

    /* ---- T3: a line the CPU READ before the DMA wrote it -------------------
     * A read fill records the reader as a sharer, so the directory knows about
     * this line and the DMA's write must invalidate it. */
    wr(PHASE_ADDR, 3);
    {
        u32 acc = 0;
        for (i = 0; i < m * n; i++)
            acc += rd(C3_ADDR + 4u * (u32)i);   /* pull the lines in, read-only */
        rec(6, acc);                            /* and keep the read from being
                                                 * optimised away */
    }
    if (run_gemm(m, n, k, C3_ADDR)) {
        good = c_check(C3_ADDR, m, n, k, &bad);
        rec(7, (u32)good);
        rec(8, bad);
        if (good == m * n)
            diag |= T3_OK;
    }

    /* ---- T1: the bug ------------------------------------------------------
     * The CPU writes the line, which takes it out of the L2's directory, and
     * the DMA then overwrites it in DDR.  A CPU that still holds its own copy
     * reads the poison back. */
    wr(PHASE_ADDR, 4);
    for (i = 0; i < m * n; i++)
        wr(C1_ADDR + 4u * (u32)i, POISON);
    if (run_gemm(m, n, k, C1_ADDR)) {
        good = c_check(C1_ADDR, m, n, k, &bad);
        rec(0, (u32)good);
        rec(1, bad);
        rec(2, POISON);
        if (good == m * n)
            diag |= T1_OK;
    }

    rec(3, (u32)(m * n));
    wr(DIAG_ADDR, diag);
    wr(RESULT_ADDR, (diag & (T1_OK | T2_OK | T3_OK)) == (T1_OK | T2_OK | T3_OK)
                    ? PASS_MAGIC : FAIL_MAGIC);
    wr(PHASE_ADDR, 0xFFu);
    wr(DONE_ADDR, DONE_MAGIC);
    for (;;) { }
}
