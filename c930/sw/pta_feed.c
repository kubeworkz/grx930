// ---------------------------------------------------------------------------
// pta_feed.c -- F2: the feed's options at the Pockels points, measured on the
// SoC (grxcp pta_program_plan.md, track F).
//
// F2 asks whether the host's feed binds the Pockels-class end, and which way of
// supplying operands is cheapest there.  It could not be asked before SoC-B:
// with PTM-C's 64-cycle drain the fetch finished in the drain's shadow, so every
// feed option measured the same.  A shot is now PTA_TS + 2 cycles, and the core
// at EO-res is a few hundred cycles rather than a few thousand, which is where a
// fixed feed cost starts to show.
//
// THE THREE OPTIONS, and how each is reached here:
//
//   1. PF1 and PF2 as built.  The DMA reads A row 0 and all of B before launch,
//      streams rows 1..M-1 during compute (PF1), and during C writeback
//      prefetches the next queued GEMM's row 0 and B into a staging buffer
//      (PF2).  This is modes = 0: nothing to ask for.
//
//   2. B tiles prefetched straight into resident banks.  That is MB's resident
//      mode, and at these settings it IS the EO-res point: RESIDENT puts a
//      weight bank per (N tile, K tile) and WSKIP says they are already loaded.
//      So the two levels below span this option rather than it being a third
//      axis -- EO-scan with RESIDENT|WSKIP would be EO-res by definition.
//
//   3. The whole GEMM staged before launch.  PTA_CTRL.STAGE_A, added for this
//      step: the DMA reads every A row before pulsing the core's start, and both
//      prefetches are off.  This is the path INT4 has always taken (nibble
//      packing makes rows share bytes); the bit asks for it at INT8, where PF1
//      is otherwise available, so the feed's placement can be measured instead
//      of argued.
//
// WHY EACH REGIME IS RUN AT TWO BATCH SIZES.  Every per-GEMM counter in this
// engine -- CYCLE_LO, DMA_CT, STALL_CT, AROW_CT -- resets on START, so a drained
// batch of four only reports its last GEMM.  The fix is not a new counter: run
// each regime at Q = 1, where the counters are exact and the CPU reads them
// between GEMMs, and again at Q = 4, where only the wall clock is read.  Then
//
//     overlap gain  =  4 * wall(Q=1)  -  wall(Q=4)
//
// is what queueing actually buys, measured rather than modelled, and it is the
// only number that prices PF2 -- whose cost F0 found to be negative at its own
// shape (it fetched 143 of 288 beats and then drained the abandoned burst).
//
// The wall clock is the CPU's own cycle CSR (0xC00), so a batch's total includes
// the submit MMIO writes and the drain polling: the host's share of the feed is
// part of what F2 is choosing between, not an error term to be subtracted.
//
// THE SHAPE IS THIS SoC'S, NOT SECTION 6.2'S -- MAX_M=8, MAX_K=16, MAX_N=12
// cannot be asked for M=64 N=8 K=256 at all (section 6.1's gap, which C4(c) and
// pta_sweep.c record too).  M=8 N=12 K=16 is kept identical to pta_sweep.c's so
// the two sets of numbers sit side by side.  Note what that does to option 3:
// A is M*K = 128 bytes, 16 beats, of which row 0 is 2 -- so staging moves 14
// beats out of the compute shadow.  At section 6.2's shape it would be 16,128
// operands, and F3 is where that scaling is handed on rather than guessed at.
//
// DDR map (the words this program owns; pta_sweep.c's layout, same addresses):
//   0x9400 : M, N, K, precision        0x9410 : DONE magic
//   0x9420 : RESULT (PASS/FAIL)        0x9480 : DIAG (a bit per point)
//   0x9490 : PHASE (progress, for a hang)
//   0x9500 : the table, 16 words a point, nine points
// ---------------------------------------------------------------------------
#include "c930_npu_driver.h"

typedef unsigned int u32;

#define A_ADDR      0x1000u
#define B_ADDR      0x2000u
#define C_ADDR      0x3000u
#define DIMS_ADDR   0x9400u
#define DONE_ADDR   0x9410u
#define RESULT_ADDR 0x9420u
#define DIAG_ADDR   0x9480u
#define PHASE_ADDR  0x9490u
#define TABLE_ADDR  0x9500u

// The tile's shape, as pta_sweep.c also has to spell it: nothing in the register
// map reports it (the same gap section 3.3 records about DIN_W).
#define NUM_COLS    8
#define NUM_ROWS    8

#define DONE_MAGIC  0xDEADBEEFu
#define PASS_MAGIC  0x0BADBEEFu
#define FAIL_MAGIC  0x0BADF00Du

#define MAX_Q       4      /* CMD_QUEUE_DEPTH */

// One row of the table per point.
#define FD_WALL     0      /* CPU cycles across the whole batch */
#define FD_CYCLES   1      /* core cycles, LAST GEMM of the batch */
#define FD_DMA_CT   2      /* DMA busy, LAST GEMM */
#define FD_DMA_LAST 3
#define FD_STALL    4      /* weight-load cycles, LAST GEMM */
#define FD_AROW     5      /* cycles the core waited for an A row, LAST GEMM */
#define FD_SHOTS    6      /* PTA_SHOT_CT delta across the batch (cumulative reg) */
#define FD_WLOADS   7      /* PTA_WLOAD_CT delta across the batch */
#define FD_COK      8      /* every C element of every GEMM in the batch */
#define FD_RAN      9
#define FD_Q        10     /* the batch size this row was measured at */
#define FD_STRIDE   16

#define P_WARM      0      /* discarded: the CPU's I-cache is cold on the first */
#define P_SCAN_Q1   1
#define P_SCAN_Q4   2
#define P_SCAN_S1   3
#define P_SCAN_S4   4
#define P_FILL      5
#define P_RES_Q1    6
#define P_RES_Q4    7
#define P_RES_S1    8
#define P_RES_S4    9
#define P_ODD       10     /* an odd M*N, for the writeback's tail beat */
#define N_POINTS    11

/* The odd-tail shape.  M*N must be odd for the C write burst's last beat to
 * carry one word instead of two (c_odd / wstrb 0x0F in c930_npu_dma.sv), and
 * every other shape this SoC runs -- 8x12 here and in pta_sweep.c, 8x8 in
 * pta_test.c -- has an even M*N, so that beat was never exercised.  3*5 = 15
 * words is 8 beats, the last of them half full. */
#define ODD_M       3
#define ODD_N       5
#define ODD_K       16

static u32  rd(u32 a)        { return *(volatile u32 *)a; }
static void wr(u32 a, u32 v) { *(volatile u32 *)a = v; }

// The CPU's cycle counter (CSR 0xC00; riscv_core_csr_unit.sv maps both cycle and
// time to the same free-running counter).  Addressed by number, not by name: the
// one other firmware that touches CSRs here (npu_test.c) encodes them as .word
// for the same reason.  32 bits is ample -- the thermo-optic points, which are
// the only ones that run into millions, are not in this program.
static u32 cyc32(void)
{
    unsigned long v;
    __asm__ volatile ("csrr %0, 0xc00" : "=r" (v));
    return (u32)v;
}

static void fd_put(int p, int slot, u32 v)
{
    wr(TABLE_ADDR + 4u * FD_STRIDE * (u32)p + 4u * (u32)slot, v);
}

static int ceil_div(int a, int b) { return (a + b - 1) / b; }

// A C block per GEMM, never reused.  Two reasons, and only the second is still
// load-bearing: the L2 used to drop a written line's directory entry (CPU
// document 3.3), which c930_l2.sv has since fixed; and every GEMM here computes
// the same C, so one reading a block an earlier GEMM had already pulled into the
// L1 would be checking that GEMM's arithmetic and would pass however wrong this
// one was.
// Assigned in main(), not just declared: start.S sets a stack and jumps, so
// nothing zeroes .bss, and objcopy -O binary does not emit it either (NOBITS) --
// so this would start as whatever the DDR model left at its address, and the C
// blocks would walk off the end of what the harness preloaded.
static int g_cblock;
static u32 c_base_of(int i) { return C_ADDR + 0x200u * (u32)i; }

// Returns 1, or a negative code naming the step that failed, so a point that
// does not run says why instead of leaving zeros behind.
#define G_SUBMIT  (-1)
#define G_DRAIN   (-2)
#define G_ERROR   (-3)
#define G_QUEUE   (-4)
#define G_CHECK   (-5)

// Every operand is 1, so every C element is exactly K with the model off.  A
// wrong bank select, or a staged A row that was never written, shows up here
// before it shows up in a cycle count.
static int c_exact(int blk, int m, int n, int k)
{
    int i;
    for (i = 0; i < m * n; i++)
        if (rd(c_base_of(blk) + 4u * (u32)i) != (u32)k)
            return 0;
    return 1;
}

static int submit_one(int blk, int m, int n, int k)
{
    npu_drv_gemm_t g;
    g.dim_m = (u32)m; g.dim_n = (u32)n; g.dim_k = (u32)k;
    g.a_base = A_ADDR; g.b_base = B_ADDR; g.c_base = c_base_of(blk);
    g.prec = NPU_PREC_INT8;
    return npu_drv_submit(&g);
}

// One batch: q GEMMs under one set of modes, submitted back to back and drained
// once.  At q = 1 that is the shipped submit-and-wait; at q = 4 the queue is
// what lets PF2 see a next GEMM at all.
static int batch(int p, int m, int n, int k, u32 tw, u32 ts, u32 modes, int q)
{
    u32 t0, t1, sh0, wl0;
    int i, blk[MAX_Q], spin;

    wr(PHASE_ADDR, 0x10u + (u32)p);
    wr(PTA_REG_TW, tw);
    wr(PTA_REG_TS, ts);
    // The engine stays off, as in pta_sweep.c: this step is about the feed's
    // cost, and a calibration inside a batch would add its own cycles.
    wr(PTA_REG_CTRL, modes);

    for (i = 0; i < q; i++)
        blk[i] = g_cblock++;

    // Cumulative counters, read before and after.  These are the only two that
    // survive a START, so they are the only batch-wide totals available.
    sh0 = rd(PTA_REG_SHOT_CT);
    wl0 = rd(PTA_REG_WLOAD_CT);

    t0 = cyc32();
    for (i = 0; i < q; i++) {
        // The FIFO is four deep and the running GEMM has been dequeued, so four
        // submissions fit -- but a full FIFO silently drops START (the driver
        // refuses instead), so this waits for room rather than assuming it.
        spin = 0;
        while (npu_drv_queue_room() <= 0) {
            if (++spin > 2000000) {
                fd_put(p, FD_RAN, (u32)G_QUEUE);
                return 0;
            }
        }
        if (submit_one(blk[i], m, n, k) != 0) {
            fd_put(p, FD_RAN, (u32)G_SUBMIT);
            return 0;
        }
    }
    if (npu_drv_drain(20000000ull) != 0) {
        fd_put(p, FD_RAN, (u32)G_DRAIN);
        return 0;
    }
    t1 = cyc32();

    if (npu_drv_error()) {
        fd_put(p, FD_RAN, (u32)G_ERROR);
        return 0;
    }

    fd_put(p, FD_WALL,     t1 - t0);
    fd_put(p, FD_CYCLES,   rd(NPU_REG_CYCLE_LO));
    fd_put(p, FD_DMA_CT,   rd(NPU_REG_DMA_CT));
    fd_put(p, FD_DMA_LAST, rd(NPU_REG_DMA_LAST));
    fd_put(p, FD_STALL,    rd(NPU_REG_STALL_CT));
    fd_put(p, FD_AROW,     rd(NPU_REG_AROW_CT));
    fd_put(p, FD_SHOTS,    rd(PTA_REG_SHOT_CT)  - sh0);
    fd_put(p, FD_WLOADS,   rd(PTA_REG_WLOAD_CT) - wl0);
    fd_put(p, FD_Q,        (u32)q);

    // Every GEMM in the batch, not just the last: a staged A that lost rows
    // 1..M-1 would still give the last GEMM the right answer if the core had
    // read a bank an earlier GEMM filled.
    for (i = 0; i < q; i++)
        if (!c_exact(blk[i], m, n, k)) {
            fd_put(p, FD_COK, 0);
            fd_put(p, FD_RAN, (u32)G_CHECK);
            return 0;
        }
    fd_put(p, FD_COK, 1);
    fd_put(p, FD_RAN, 1);
    return 1;
}

int main(void)
{
    int m, n, k, nt, kt, p;
    u32 diag = 0;
    const u32 RES = PTA_CTRL_RESIDENT | PTA_CTRL_WSKIP;

    g_cblock = 0;        // see its declaration: nothing zeroes .bss here

    wr(DONE_ADDR, 0);
    wr(RESULT_ADDR, 0);
    wr(DIAG_ADDR, 0);
    wr(PHASE_ADDR, 1);

    m = (int)rd(DIMS_ADDR + 0);
    n = (int)rd(DIMS_ADDR + 4);
    k = (int)rd(DIMS_ADDR + 8);
    nt = ceil_div(n, NUM_COLS);
    kt = ceil_div(k, NUM_ROWS);

    npu_drv_mmio(NPU0_BASE);

    // One discarded GEMM first.  The wall clock is the CPU's, so the first
    // batch pays for fetching submit, drain and this function through a cold
    // I-cache: measured at ~290 cycles on 2,023, which is 14% -- bigger than
    // every difference F2 is trying to read.
    if (batch(P_WARM, m, n, k, 0u, 1u, 0u, 1)) diag |= 1u << P_WARM;

    // EO-scan next, all of it, before anything fills a resident bank.  With
    // RESIDENT off the core writes the rotating bank_sel, which would overwrite
    // a bank the resident points below expect to still hold its tile.
    if (batch(P_SCAN_Q1, m, n, k, 0u, 1u, 0u, 1)) diag |= 1u << P_SCAN_Q1;
    if (batch(P_SCAN_Q4, m, n, k, 0u, 1u, 0u, 4)) diag |= 1u << P_SCAN_Q4;
    if (batch(P_SCAN_S1, m, n, k, 0u, 1u, PTA_CTRL_STAGE_A, 1)) diag |= 1u << P_SCAN_S1;
    if (batch(P_SCAN_S4, m, n, k, 0u, 1u, PTA_CTRL_STAGE_A, 4)) diag |= 1u << P_SCAN_S4;

    // The fill: every (N tile, K tile) written to its own bank at the scan's
    // usual cost.  One GEMM, and the four EO-res batches below all skip the
    // load, so the banks stay valid across them.
    if (batch(P_FILL, m, n, k, 0u, 1u, PTA_CTRL_RESIDENT, 1)) diag |= 1u << P_FILL;

    if (batch(P_RES_Q1, m, n, k, 0u, 1u, RES, 1)) diag |= 1u << P_RES_Q1;
    if (batch(P_RES_Q4, m, n, k, 0u, 1u, RES, 4)) diag |= 1u << P_RES_Q4;
    if (batch(P_RES_S1, m, n, k, 0u, 1u, RES | PTA_CTRL_STAGE_A, 1)) diag |= 1u << P_RES_S1;
    if (batch(P_RES_S4, m, n, k, 0u, 1u, RES | PTA_CTRL_STAGE_A, 4)) diag |= 1u << P_RES_S4;

    // The writeback's tail beat, at the only shape here with an odd M*N.  Not a
    // timing point -- a correctness one, and it is in this program because this
    // is where the write burst was restructured.
    if (batch(P_ODD, ODD_M, ODD_N, ODD_K, 0u, 1u, 0u, 1)) diag |= 1u << P_ODD;

    // Leave the modes as the shipped ones, so nothing downstream inherits a
    // half-set experiment.
    wr(PTA_REG_CTRL, 0u);

    // What the shape was, so the harness does not have to assume it.
    wr(TABLE_ADDR + 4u * FD_STRIDE * N_POINTS + 0u, (u32)nt);
    wr(TABLE_ADDR + 4u * FD_STRIDE * N_POINTS + 4u, (u32)kt);
    wr(TABLE_ADDR + 4u * FD_STRIDE * N_POINTS + 8u, (u32)g_cblock);

    {
        int all = 1;
        for (p = 0; p < N_POINTS; p++) {
            if (!(diag & (1u << p))) all = 0;
            if (rd(TABLE_ADDR + 4u * FD_STRIDE * (u32)p + 4u * FD_COK) != 1u)
                all = 0;
        }
        wr(RESULT_ADDR, all ? PASS_MAGIC : FAIL_MAGIC);
    }

    wr(DIAG_ADDR, diag);
    wr(PHASE_ADDR, 0xFFu);
    wr(DONE_ADDR, DONE_MAGIC);
    for (;;) { }
}
