// ---------------------------------------------------------------------------
// act_csr.c -- A-CSR: S_ACT reached from the host, gated on the SoC
// (grxcp pta_program_plan.md, track A; doc/npu_act_stage_design_note.md 4).
//
// A-CSR landed the register block in c930_npu_csr.sv: four scalar words plus an
// indirect window at IADDR/IDATA carrying everything that is not a scalar -- the
// per-column scales, the 1025-breakpoint table and the three counters.  Nothing
// had ever driven it.  This is that firmware, and the gate it owes.
//
// THE GATE IS A1'S, DRIVEN FROM THE HOST SIDE.  The core bench's A1 configures
// S_ACT through the DUT's ports: unit scales, no noise, no detuning, no
// requantisation, the identity table, and then C must equal the digital
// reference exactly.  That is the right check to repeat here, because it fails
// on every way the indirect window can be wrong -- a region decode that lands in
// the wrong memory, an auto-increment that skips or repeats, a breakpoint
// truncated on its way through [23:0], a scale written to the wrong column.
// None of those need a transfer curve to catch, and all of them survive a
// readback-only test.
//
// With every operand 1 and K = 16 the unactivated C is exactly 16, and the
// identity configuration must leave it there.  The arithmetic, since it is the
// thing being trusted: stage 1 gives x = acc * XS >>> XSHIFT = 16 at XS = 1; the
// table's breakpoint i holds -2^23 + i * 2^14, so u = x + 2^23 indexes i = 512
// with a fraction of 16/2^14 and the interpolation returns x exactly; stage 6
// gives yr = y * R >>> 12 = y at R = 4096 and then C = yr << YSHIFT = y at
// YSHIFT = 0.  So C = 16 = K, and anything else is a fault in the path this
// program is testing rather than in the curve.
//
// WHAT ELSE IS CHECKED, and why each needs firmware rather than the core bench:
//
//   - The indirect window's auto-increment is write-only.  Writing IDATA
//     increments IADDR; reading it does not (c930_npu_csr.sv has exactly two
//     assignments to act_iaddr).  So a readback has to re-address every entry,
//     and a firmware that assumed the symmetry would read column 0 eight times
//     and pass.  Checked by writing a distinct value per column.
//
//   - An index past NUM_COLS is dropped, not wrapped.  The RTL guards the scale
//     writes with `if (act_iaddr < NUM_COLS)`; nothing had shown that the guard
//     holds, and a wrap would corrupt column 0 from column 8.
//
//   - IR_TBL reads as zero.  The core owns the table's only read port, so the
//     region is write-only by design.  Worth pinning down, because the RTL's own
//     comment used to claim a dropped write was visible in the readback -- it is
//     not, and this is where that was found.
//
//   - A breakpoint write while the core is busy is dropped.  That is the rule the
//     write port needs (the table is read combinationally while S_ACT runs) and
//     it cannot be observed directly, for the reason above.  What shows it is the
//     activation's output: breakpoint 512 moved from 0 to 1000 takes C from 16 to
//     1015, so the same write is made twice -- once with a GEMM in flight, where
//     C must stay 16, and once idle, where C must become 1015.  Two points, not
//     one: without the second the first passes on a write path that never worked.
//
//   - REQUANT rides the queue entry.  The design note calls it snapshotted at
//     START; the implementation is stronger -- `o_act_requant = fifo_head[...]`,
//     so it is captured when the command is pushed and a later write cannot reach
//     it.  Two GEMMs are queued with the bit flipped between them and each must
//     come back with its own value: at adc_bits = 6 the requantiser computes
//     ((16 + 2^17) >> 18) << 18 = 0, so one block reads 16 and the other 0.
//
//   - r_j = 65536 wraps to zero.  Q4.12's largest representable value is
//     65535/4096 = 15.9998, not 16, so s = 1/16 exactly asks for 65536 and the
//     register's [15:0] silently stores 0 -- which turns that column off rather
//     than scaling it.  Section 7.2 of the design note found this in the chain
//     harness; this records that the CSR path has it too, so the one place a
//     reciprocal is computed can refuse it.
//
// DDR map (the words this program owns):
//   0x9400 : M, N, K, precision        0x9410 : DONE magic
//   0x9420 : RESULT (PASS/FAIL)        0x9490 : PHASE (progress, for a hang)
//   0x9500 : the table, 8 words a point, eleven points
// ---------------------------------------------------------------------------
#include "c930_npu_driver.h"

typedef unsigned int u32;

#define A_ADDR      0x1000u
#define B_ADDR      0x2000u
#define C_ADDR      0x3000u
#define DIMS_ADDR   0x9400u
#define DONE_ADDR   0x9410u
#define RESULT_ADDR 0x9420u
#define PHASE_ADDR  0x9490u
#define TABLE_ADDR  0x9500u

#define DONE_MAGIC  0xDEADBEEFu
#define PASS_MAGIC  0x0BADBEEFu
#define FAIL_MAGIC  0x0BADF00Du

// The tile's shape and the activation's latency.  Spelled here because nothing
// in the register map reports either -- the same gap section 3.3 of the design
// note records about DIN_W.  NUM_COLS and ACT_P are c930_npu_core.sv's.
#define NUM_COLS    8
#define ACT_P       8
#define ACT_TBL     1025      /* breakpoints: 1024 segments */

#define DIM_M       8
#define DIM_N       12
#define DIM_K       16

// The identity configuration, as gate A1 sets it.
#define ID_XS       1u        /* x = acc * XS >>> XSHIFT */
#define ID_R        4096u     /* 1/s_j in Q4.12, so unity */
#define ID_ADC_BITS 6u        /* unused with REQUANT off; the requant point uses it */

// Breakpoint 512 is the one x = 16 interpolates from, and 1000 there takes the
// activated C from 16 to 1000 + ((16384 - 1000) * 16 >> 14) = 1015.
#define TBL_PROBE_I 512u
#define TBL_PROBE_V 1000u
#define C_PROBED    1015u

// Requantisation with adc_bits = 6 shifts by S = 24 - 6 = 18, so the activated
// C of 16 becomes ((16 + 2^17) >> 18) << 18 = 0.
#define C_REQUANT   0u

// One row of the result table per point.
#define AC_RAN      0        /* 1, or a negative code naming the step that failed */
#define AC_PASS     1
#define AC_OBS      2        /* what was seen */
#define AC_WANT     3        /* what was wanted */
#define AC_EXTRA    4        /* a second observation, where a point has one */
#define AC_STRIDE   8

#define P_SCALARS   0
#define P_XS        1
#define P_R         2
#define P_OOR       3
#define P_TBLRD     4
#define P_IDENT     5
#define P_COUNT     6
#define P_BUSYDROP  7
#define P_IDLEWR    8
#define P_REQUANT   9
#define P_SNAPSHOT  10
#define P_RWRAP     11
#define N_POINTS    12

#define G_SUBMIT  (-1)
#define G_DRAIN   (-2)
#define G_ERROR   (-3)
#define G_NOTBUSY (-4)       /* the busy window was missed, so nothing was shown */

static u32  rd(u32 a)        { return *(volatile u32 *)a; }
static void wr(u32 a, u32 v) { *(volatile u32 *)a = v; }

static void ac_put(int p, int slot, u32 v)
{
    wr(TABLE_ADDR + 4u * AC_STRIDE * (u32)p + 4u * (u32)slot, v);
}

// ran, pass, observed, wanted -- one call so a point cannot record half of itself.
static void ac_row(int p, int ran, int pass, u32 obs, u32 want, u32 extra)
{
    ac_put(p, AC_RAN,   (u32)ran);
    ac_put(p, AC_PASS,  (u32)(pass ? 1 : 0));
    ac_put(p, AC_OBS,   obs);
    ac_put(p, AC_WANT,  want);
    ac_put(p, AC_EXTRA, extra);
}

// ---- the indirect window ---------------------------------------------------
// A write is address-then-data; the address then moves on by itself, so a run of
// entries is one address write and n data writes.
static void ind_seek(u32 region, u32 index) { wr(ACT_REG_IADDR, region | index); }
static void ind_put(u32 v)                  { wr(ACT_REG_IDATA, v); }

// A read is address-then-read EVERY time: IADDR does not move on a read.
static u32 ind_get(u32 region, u32 index)
{
    ind_seek(region, index);
    return rd(ACT_REG_IDATA);
}

// ---- the activation's configuration ---------------------------------------
#define ACT_CFG_FIELDS(k, adc, xsh, ysh) \
    (((k) & 0xFFFFu) | (((adc) & 0xFu) << 16) | \
     (((xsh) & 0x3Fu) << 20) | (((ysh) & 0x3Fu) << 26))

// The identity table, computed rather than carried: breakpoint i is
// -2^23 + i * 2^14, saturated at 2^23 - 1, which is what the core bench's
// identity_table() builds.  1025 words through one window: one address write,
// 1025 data writes.
static void load_identity_table(void)
{
    u32 i;
    ind_seek(ACT_IR_TBL, 0u);
    for (i = 0; i < ACT_TBL; i++) {
        int v = -0x800000 + (int)(i << 14);
        if (v > 0x7FFFFF) v = 0x7FFFFF;
        ind_put((u32)v & 0xFFFFFFu);
    }
}

static void load_identity_scales(void)
{
    int j;
    ind_seek(ACT_IR_XS, 0u);
    for (j = 0; j < NUM_COLS; j++) ind_put(ID_XS);
    ind_seek(ACT_IR_R, 0u);
    for (j = 0; j < NUM_COLS; j++) ind_put(ID_R);
}

// S_ACT's cycle count for one GEMM, which is what IR_CNT slot 2 reports: S_ACT
// replaces S_WRITE on the last K tile and runs nc + ACT_P cycles instead of nc,
// M times per N tile.
static u32 want_act_cycles(int m, int n)
{
    u32 c = 0;
    int nb;
    for (nb = 0; nb < n; nb += NUM_COLS) {
        int nc = n - nb;
        if (nc > NUM_COLS) nc = NUM_COLS;
        c += (u32)m * (u32)(nc + ACT_P);
    }
    return c;
}

// A C block per GEMM, never reused: every GEMM here computes the same C, so one
// reading a block an earlier GEMM already pulled into the L1 would be checking
// that GEMM's arithmetic.  Assigned in main because start.S does not zero .bss.
static int g_cblock;
static u32 c_base_of(int i) { return C_ADDR + 0x200u * (u32)i; }

static int c_all(int blk, int m, int n, u32 want)
{
    int i;
    for (i = 0; i < m * n; i++)
        if (rd(c_base_of(blk) + 4u * (u32)i) != want)
            return 0;
    return 1;
}

static u32 c_first(int blk) { return rd(c_base_of(blk)); }

static int submit_one(int blk)
{
    npu_drv_gemm_t g;
    g.dim_m = DIM_M; g.dim_n = DIM_N; g.dim_k = DIM_K;
    g.a_base = A_ADDR; g.b_base = B_ADDR; g.c_base = c_base_of(blk);
    g.prec = NPU_PREC_INT8;
    return npu_drv_submit(&g);
}

// One GEMM, submitted and drained, into a fresh block.  Returns the block or a
// negative code.
static int run_one(void)
{
    int blk = g_cblock++;
    if (submit_one(blk) != 0) return G_SUBMIT;
    if (npu_drv_drain(2000000ull) != 0) return G_DRAIN;
    if (npu_drv_error()) return G_ERROR;
    return blk;
}

// ---------------------------------------------------------------------------
int main(void)
{
    u32 v, w, obs;
    int blk, blk2, ok, i, busy_seen;

    g_cblock = 0;
    npu_drv_mmio(NPU0_BASE);
    wr(PHASE_ADDR, 0x01u);
    wr(RESULT_ADDR, 0u);

    // ---- P_SCALARS: the four scalar words read back what was written -------
    wr(PHASE_ADDR, 0x10u + P_SCALARS);
    v = ACT_CFG_FIELDS(0x1234u, ID_ADC_BITS, 5u, 9u);
    wr(ACT_REG_CFG, v);
    wr(ACT_REG_SEED, 0xC0FFEE11u);
    wr(ACT_REG_CTRL, ACT_CTRL_NOISE_CONST | ACT_CTRL_REQUANT);
    ok = (rd(ACT_REG_CFG) == v) &&
         (rd(ACT_REG_SEED) == 0xC0FFEE11u) &&
         (rd(ACT_REG_CTRL) == (ACT_CTRL_NOISE_CONST | ACT_CTRL_REQUANT));
    ac_row(P_SCALARS, 1, ok, rd(ACT_REG_CFG), v, rd(ACT_REG_CTRL));

    // ---- P_XS: a distinct value per column, so the auto-increment shows ----
    // Reads do not increment, so every readback re-addresses.  Were that
    // assumed symmetric this would read column 0 eight times and pass.
    wr(PHASE_ADDR, 0x10u + P_XS);
    ind_seek(ACT_IR_XS, 0u);
    for (i = 0; i < NUM_COLS; i++) ind_put(0x11110000u + (u32)i);
    ok = 1; obs = 0;
    for (i = 0; i < NUM_COLS; i++) {
        u32 g = ind_get(ACT_IR_XS, (u32)i);
        if (g != 0x11110000u + (u32)i) { ok = 0; if (!obs) obs = g; }
    }
    ac_row(P_XS, 1, ok, obs, 0x11110000u, (u32)NUM_COLS);

    // ---- P_R: the same for the 16-bit region ------------------------------
    wr(PHASE_ADDR, 0x10u + P_R);
    ind_seek(ACT_IR_R, 0u);
    for (i = 0; i < NUM_COLS; i++) ind_put(0x1000u + (u32)i);
    ok = 1; obs = 0;
    for (i = 0; i < NUM_COLS; i++) {
        u32 g = ind_get(ACT_IR_R, (u32)i);
        if (g != 0x1000u + (u32)i) { ok = 0; if (!obs) obs = g; }
    }
    ac_row(P_R, 1, ok, obs, 0x1000u, (u32)NUM_COLS);

    // ---- P_OOR: an index past NUM_COLS is dropped, not wrapped ------------
    wr(PHASE_ADDR, 0x10u + P_OOR);
    w = ind_get(ACT_IR_XS, 0u);
    ind_seek(ACT_IR_XS, (u32)NUM_COLS);
    ind_put(0xDEADBEEFu);
    obs = ind_get(ACT_IR_XS, 0u);
    ac_row(P_OOR, 1, obs == w, obs, w, 0xDEADBEEFu);

    // ---- P_TBLRD: the table is write-only from here -----------------------
    wr(PHASE_ADDR, 0x10u + P_TBLRD);
    ind_seek(ACT_IR_TBL, 4u);
    ind_put(0x00ABCDEFu);
    obs = ind_get(ACT_IR_TBL, 4u);
    ac_row(P_TBLRD, 1, obs == 0u, obs, 0u, 0u);

    // ---- P_IDENT: A1's check, driven through the CSR -----------------------
    // Everything the activation needs, loaded from the host: the table, the
    // scales, and a configuration with no noise, no detuning, no requantisation.
    wr(PHASE_ADDR, 0x10u + P_IDENT);
    wr(ACT_REG_CTRL, 0u);                       // off while the table loads
    wr(ACT_REG_CFG, ACT_CFG_FIELDS(0u, ID_ADC_BITS, 0u, 0u));
    wr(ACT_REG_SEED, 1u);
    load_identity_table();
    load_identity_scales();

    blk = run_one();                            // the reference: S_ACT disabled
    if (blk < 0) { ac_row(P_IDENT, blk, 0, 0u, (u32)DIM_K, 0u); goto report; }
    ok = c_all(blk, DIM_M, DIM_N, (u32)DIM_K);
    obs = c_first(blk);

    wr(ACT_REG_CTRL, ACT_CTRL_EN);
    blk2 = run_one();                           // and through the identity table
    if (blk2 < 0) { ac_row(P_IDENT, blk2, 0, obs, (u32)DIM_K, 0u); goto report; }
    ok = ok && c_all(blk2, DIM_M, DIM_N, (u32)DIM_K);
    ac_row(P_IDENT, 1, ok, c_first(blk2), (u32)DIM_K, obs);

    // ---- P_COUNT: the three counters, read through IR_CNT ------------------
    // Read after the activated GEMM above, so they describe it.
    wr(PHASE_ADDR, 0x10u + P_COUNT);
    {
        u32 n_act = ind_get(ACT_IR_CNT, ACT_CNT_ACTIVATED);
        u32 n_sat = ind_get(ACT_IR_CNT, ACT_CNT_SATS);
        u32 n_cyc = ind_get(ACT_IR_CNT, ACT_CNT_CYCLES);
        u32 want  = want_act_cycles(DIM_M, DIM_N);
        ok = (n_act == (u32)(DIM_M * DIM_N)) && (n_sat == 0u) && (n_cyc == want);
        ac_put(P_COUNT, AC_RAN,  1u);
        ac_put(P_COUNT, AC_PASS, ok ? 1u : 0u);
        ac_put(P_COUNT, AC_OBS,  n_cyc);
        ac_put(P_COUNT, AC_WANT, want);
        ac_put(P_COUNT, AC_EXTRA, n_act);
        ac_put(P_COUNT, 5, n_sat);
    }

    // ---- P_BUSYDROP: a breakpoint write while busy is dropped -------------
    // Submitted, then written into while the core is still running.  BUSY is
    // sampled just before the data write: if the window was missed the point
    // reports that rather than passing on nothing.
    wr(PHASE_ADDR, 0x10u + P_BUSYDROP);
    blk = g_cblock++;
    if (submit_one(blk) != 0) { ac_row(P_BUSYDROP, G_SUBMIT, 0, 0u, (u32)DIM_K, 0u); goto report; }
    ind_seek(ACT_IR_TBL, TBL_PROBE_I);
    busy_seen = (npu_drv_status() & NPU_STATUS_BUSY) ? 1 : 0;
    ind_put(TBL_PROBE_V);
    if (npu_drv_drain(2000000ull) != 0) { ac_row(P_BUSYDROP, G_DRAIN, 0, 0u, (u32)DIM_K, 0u); goto report; }
    obs = c_first(blk);
    if (!busy_seen)
        ac_row(P_BUSYDROP, G_NOTBUSY, 0, obs, (u32)DIM_K, 0u);
    else
        ac_row(P_BUSYDROP, 1, c_all(blk, DIM_M, DIM_N, (u32)DIM_K),
               obs, (u32)DIM_K, 1u);

    // ---- P_IDLEWR: the same write, idle, does change the curve ------------
    // Without this the point above passes on a write path that never worked.
    wr(PHASE_ADDR, 0x10u + P_IDLEWR);
    ind_seek(ACT_IR_TBL, TBL_PROBE_I);
    ind_put(TBL_PROBE_V);
    blk = run_one();
    if (blk < 0) { ac_row(P_IDLEWR, blk, 0, 0u, C_PROBED, 0u); goto report; }
    ac_row(P_IDLEWR, 1, c_all(blk, DIM_M, DIM_N, C_PROBED),
           c_first(blk), C_PROBED, 0u);

    // Put breakpoint 512 back, so the points below are on the identity curve.
    ind_seek(ACT_IR_TBL, TBL_PROBE_I);
    ind_put(0u);

    // ---- P_REQUANT: requantisation works at all, unqueued ------------------
    // The control for the point below: without it a failed snapshot cannot say
    // whether the queue lost the bit or the requantiser never ran.
    wr(PHASE_ADDR, 0x10u + P_REQUANT);
    wr(ACT_REG_CTRL, ACT_CTRL_EN | ACT_CTRL_REQUANT);
    blk = run_one();
    if (blk < 0) { ac_row(P_REQUANT, blk, 0, 0u, C_REQUANT, 0u); goto report; }
    ac_row(P_REQUANT, 1, c_all(blk, DIM_M, DIM_N, C_REQUANT),
           c_first(blk), C_REQUANT, 0u);

    // ---- P_SNAPSHOT: REQUANT rides the queue entry ------------------------
    // Two GEMMs queued with the bit flipped between them.  At adc_bits = 6 the
    // requantiser gives ((16 + 2^17) >> 18) << 18 = 0, so the first block must
    // read K and the second 0 -- and the harness preloads these two blocks with
    // a sentinel, so a GEMM that never ran cannot pass the second check.
    wr(PHASE_ADDR, 0x10u + P_SNAPSHOT);
    wr(ACT_REG_CTRL, ACT_CTRL_EN);              // REQUANT clear
    blk = g_cblock++;
    if (submit_one(blk) != 0) { ac_row(P_SNAPSHOT, G_SUBMIT, 0, 0u, (u32)DIM_K, 0u); goto report; }
    wr(ACT_REG_CTRL, ACT_CTRL_EN | ACT_CTRL_REQUANT);
    blk2 = g_cblock++;
    if (submit_one(blk2) != 0) { ac_row(P_SNAPSHOT, G_SUBMIT, 0, 0u, (u32)DIM_K, 0u); goto report; }
    if (npu_drv_drain(2000000ull) != 0) { ac_row(P_SNAPSHOT, G_DRAIN, 0, 0u, (u32)DIM_K, 0u); goto report; }
    ok = c_all(blk, DIM_M, DIM_N, (u32)DIM_K) &&
         c_all(blk2, DIM_M, DIM_N, C_REQUANT);
    ac_row(P_SNAPSHOT, 1, ok, c_first(blk), (u32)DIM_K, c_first(blk2));

    // ---- P_RWRAP: r_j = 65536 wraps to zero -------------------------------
    // Q4.12 represents 65535/4096 = 15.9998 and not 16, so s = 1/16 exactly asks
    // for a value the register cannot hold and [15:0] stores 0 -- which turns
    // that column off instead of scaling it.  Recorded so the one place a
    // reciprocal is computed can refuse it.
    wr(PHASE_ADDR, 0x10u + P_RWRAP);
    ind_seek(ACT_IR_R, 0u);
    ind_put(65536u);
    obs = ind_get(ACT_IR_R, 0u);
    ac_row(P_RWRAP, 1, obs == 0u, obs, 0u, 65535u);

report:
    wr(ACT_REG_CTRL, 0u);
    {
        int pass = 1;
        for (i = 0; i < N_POINTS; i++) {
            u32 ran = rd(TABLE_ADDR + 4u * AC_STRIDE * (u32)i + 4u * AC_RAN);
            u32 p   = rd(TABLE_ADDR + 4u * AC_STRIDE * (u32)i + 4u * AC_PASS);
            if (ran != 1u || p != 1u) pass = 0;
        }
        wr(RESULT_ADDR, pass ? PASS_MAGIC : FAIL_MAGIC);
    }
    wr(PHASE_ADDR, 0xFFu);
    wr(DONE_ADDR, DONE_MAGIC);
    for (;;) { }
    return 0;
}
