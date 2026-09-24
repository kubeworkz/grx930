// -----------------------------------------------------------------------------
// pta_test.c - Firmware smoke test for the PTA register block (phase C4(a)).
//
// Boots on CPU0 of the SoC and drives the photonic tile the way a driver will
// have to: through the block at PTA_BASE, with nothing but MMIO reads and
// writes.  The harness gives it all-ones operands, so C is K everywhere with
// nothing impaired and the firmware needs no reference of its own -- which keeps
// it short enough to run on a four-core SoC model.
//
// Seven checks, and a bitmap of what passed at DIAG so a failure says which:
//
//   T1  the decode.  Patterns written across the block read back, and the
//       registers below 0x40 -- which the widening had to leave alone -- still
//       read back too.
//   T2  the counters.  PTA_SHOT_CT and PTA_WLOAD_CT advance by exactly what the
//       shape says: M * n_tiles * k_tiles shots and n_tiles * k_tiles
//       programmings.  Nothing else in this build produces those numbers.
//   T3  the tile is listening.  With nothing impaired C is K; with QUANT and a
//       four-bit ADC at S = 8 a K tile's y = 2048 becomes (2048 + 2^15) >>> 16
//       = 0, so C is nothing.  Both values come from the contract.
//   T4  a calibration.  CAL_NOW, then poll: CAL_CT goes up by one, CAL_VALID is
//       set, CAL_ERR is clear, and PTA_ERR_FOUND is not zero, because there was
//       drift to find.
//   T5  the dispatch guard (grxcp pta_cpu_integration.md section 3.2).  A GEMM
//       submitted while CAL_BUSY is set has to queue, not dispatch and not
//       vanish: occupancy 1, STATUS.BUSY clear, and the GEMM runs afterwards.
//   T6  MODEL_RST clears the correction.  A column's gain and offset written and
//       read back, then MODEL_RST, then unity and zero again.
//   T7  the refusal.  MZM_NL has no phase in this build, so a START carrying it
//       raises STATUS.ERROR and runs nothing; the next valid START clears it.
//
// A build with the digital array refuses every impairment, so T3 detects that
// and records it in DIAG rather than failing; the harness knows which build it
// is and asserts accordingly.
//
// DDR layout (byte addresses), sharing driver_test.c's where they overlap:
//   0x1000 : A (M*K bytes, INT8)          0x2000 : B (K*N bytes, INT8)
//   0x3000 : C (M*N*4 bytes)              0x9400 : dims (M, N, K, prec)
//   0x9410 : DONE magic                   0x9420 : RESULT (PASS/FAIL)
//   0x9430 : recorded values, 16 words    0x9480 : DIAG (the bitmap)
//   0x9490 : PHASE (how far it got)
// -----------------------------------------------------------------------------

#include "c930_npu_driver.h"

typedef unsigned int u32;

#define A_ADDR      0x1000u
#define B_ADDR      0x2000u
#define C_ADDR      0x3000u
#define DIMS_ADDR   0x9400u
#define DONE_ADDR   0x9410u
#define RESULT_ADDR 0x9420u
#define REC_ADDR    0x9430u
#define DIAG_ADDR   0x9480u
#define PHASE_ADDR  0x9490u

#define DONE_MAGIC  0xDEADBEEFu
#define PASS_MAGIC  0x0BADBEEFu
#define FAIL_MAGIC  0x0BADF00Du

#define T1_OK       0x001u
#define T2_OK       0x002u
#define T3_OK       0x004u
#define T4_OK       0x008u
#define T5_OK       0x010u
#define T6_OK       0x020u
#define T7_OK       0x040u
#define DIGITAL     0x100u   /* the array build: nothing to impair */

#define NUM_COLS    8
#define NUM_ROWS    8

static u32  rd(u32 a)         { return *(volatile u32 *)a; }
static void wr(u32 a, u32 v)  { *(volatile u32 *)a = v; }
static void rec(int i, u32 v) { wr(REC_ADDR + 4u * (u32)i, v); }

static int ceil_div(int a, int b) { return (a + b - 1) / b; }

/* Every element of C equal to want?  The operands are all ones, so "want" is a
 * number the contract gives, not a reference computed here.
 *
 * C is never written from here, only read.  It cannot be: c930_l2.sv records a
 * sharer on a read fill and drops the line on a write, so a line the CPU has
 * written is one the L2 no longer tracks -- the NPU DMA's write to it then
 * invalidates nobody and the CPU reads its own stale value for ever.  Clearing
 * C first is therefore the one thing this test must not do; each GEMM writes
 * every element anyway, so a check that C *became* the expected value is
 * stronger than one against a cleared buffer. */
static int c_all(int m, int n, int want)
{
    int i;
    for (i = 0; i < m * n; i++)
        if ((int)rd(C_ADDR + (u32)(i * 4)) != want)
            return 0;
    return 1;
}

/* One GEMM through the driver, so the widened decode is exercised by the path a
 * driver uses.  Returns 0 if the engine refused it. */
static int run_gemm(int m, int n, int k)
{
    npu_drv_gemm_t g;
    g.dim_m = (u32)m; g.dim_n = (u32)n; g.dim_k = (u32)k;
    g.a_base = A_ADDR; g.b_base = B_ADDR; g.c_base = C_ADDR;
    g.prec = NPU_PREC_INT8;
    /* submit, drain and error all report 0 for "nothing wrong": drain is a
     * status code, not a predicate, and reading it as one is how this test
     * first reported a GEMM that had in fact run. */
    if (npu_drv_submit(&g) != 0)
        return 0;
    if (npu_drv_drain(4000000ull) != 0)
        return 0;
    return npu_drv_error() ? 0 : 1;
}

/* A probe amplitude this tile accepts.
 *
 * PTA_CAL_CFG.amp is an absolute bit position: the engine takes it only in
 * [DIN_W - B_a, DIN_W - 2], because the activation quantiser has to leave the
 * probe alone.  Nothing in the register map tells firmware what DIN_W is, so a
 * value that is right for one build is refused by another -- amp 6 is right for
 * tb_c930_npu's 8-bit tile and refused by this SoC's 16-bit one.  A driver
 * therefore has to find one, which it can: the refusal is visible in CAL_ERR,
 * a refused attempt ends in two cycles, and MODEL_RST is what clears it.
 *
 * Called before the impairments are set up, because MODEL_RST resets the model
 * with the correction and would throw away the drift the test accumulates. */
static int cal_amp_find(void)
{
    int amp;
    u32 ct0, spin, st;

    for (amp = 14; amp >= 2; amp--) {
        wr(PTA_REG_CTRL, PTA_CTRL_MODEL_RST);        /* clears a stale CAL_ERR */
        wr(PTA_REG_CAL_CFG, PTA_CAL_CFG_FIELDS(amp, 0, 1, 0));
        ct0 = rd(PTA_REG_CAL_CT);
        wr(PTA_REG_CTRL, PTA_CTRL_EN | PTA_CTRL_CAL_NOW);

        for (spin = 0; spin < 200000u; spin++) {
            st = rd(PTA_REG_STATUS);
            if ((st & PTA_ST_CAL_ERR) != 0)
                break;                               /* refused: go smaller */
            /* CAL_BUSY is asserted for the refusal's two cycles too, so the
             * accept is CAL_CT advancing, not the tile having been taken. */
            if ((st & PTA_ST_CAL_BUSY) == 0 && rd(PTA_REG_CAL_CT) != ct0) {
                wr(PTA_REG_CTRL, 0);
                return amp;
            }
        }
    }
    wr(PTA_REG_CTRL, 0);
    return -1;
}

int main(void)
{
    u32 diag = 0;
    int m, n, k, nt, kt, digital = 0;
    u32 shots0, wload0, shots1, wload1;

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

    /* ---- T1: the decode ------------------------------------------------- */
    wr(PHASE_ADDR, 2);
    {
        int ok = 1;
        wr(PTA_REG_SEED, 0x12345678u);
        rec(15, rd(PTA_REG_SEED));        /* what a read of the block returns */
        rec(9, rd(NPU_REG_QUEUE_MAX));    /* and of a register that predates it */
        wr(PTA_REG_BITS, PTA_BITS_FIELDS(6, 5, 7, 9));
        wr(PTA_REG_DRIFT, 0x000A0037u);
        wr(PTA_REG_CAL_PER, 0x00001234u);
        wr(PTA_REG_CAL_THR, 0x00ABCDEFu);
        wr(PTA_REG_CAL_CFG, PTA_CAL_CFG_FIELDS(6, 2, 3, 1));
        wr(PTA_REG_TRIM, PTA_TRIM_FIELDS(2, 0x2000));
        wr(PTA_REG_GAIN(3), 300);
        wr(PTA_REG_OFFS(5), 0xFFFFFFF9u);
        ok &= (rd(PTA_REG_SEED)    == 0x12345678u);
        ok &= (rd(PTA_REG_BITS)    == PTA_BITS_FIELDS(6, 5, 7, 9));
        ok &= (rd(PTA_REG_DRIFT)   == 0x000A0037u);
        ok &= (rd(PTA_REG_CAL_PER) == 0x00001234u);
        ok &= (rd(PTA_REG_CAL_THR) == 0x00ABCDEFu);
        ok &= (rd(PTA_REG_CAL_CFG) == PTA_CAL_CFG_FIELDS(6, 2, 3, 1));
        ok &= (rd(PTA_REG_TRIM)    == PTA_TRIM_FIELDS(2, 0x2000));
        ok &= (rd(PTA_REG_GAIN(3)) == 300);
        ok &= (rd(PTA_REG_OFFS(5)) == 0xFFFFFFF9u);
        wr(NPU_REG_DIM_M, (u32)m);
        ok &= (rd(NPU_REG_DIM_M) == (u32)m);
        ok &= (rd(NPU_REG_QUEUE_MAX) == NPU_QUEUE_DEPTH);
        if (ok) diag |= T1_OK;
    }

    /* ---- T6: MODEL_RST clears the correction ---------------------------- */
    wr(PHASE_ADDR, 3);
    {
        int ok;
        wr(PTA_REG_GAIN(2), 300);
        wr(PTA_REG_OFFS(2), 11);
        ok = (rd(PTA_REG_GAIN(2)) == 300) && (rd(PTA_REG_OFFS(2)) == 11);
        wr(PTA_REG_CTRL, PTA_CTRL_MODEL_RST);
        ok &= (rd(PTA_REG_GAIN(2)) == 256) && (rd(PTA_REG_OFFS(2)) == 0);
        if (ok) diag |= T6_OK;
    }

    /* ---- T2: the counters, against the shape ---------------------------- */
    wr(PHASE_ADDR, 4);
    wr(PTA_REG_IMPAIR, 0);
    wr(PTA_REG_BITS, 0);
    shots0 = rd(PTA_REG_SHOT_CT);
    wload0 = rd(PTA_REG_WLOAD_CT);
    if (!run_gemm(m, n, k)) {
        wr(DIAG_ADDR, diag);
        wr(RESULT_ADDR, FAIL_MAGIC);
        wr(DONE_ADDR, DONE_MAGIC);
        for (;;) ;
    }
    shots1 = rd(PTA_REG_SHOT_CT);
    wload1 = rd(PTA_REG_WLOAD_CT);
    rec(0, shots1 - shots0);
    rec(1, wload1 - wload0);
    rec(2, (u32)(m * nt * kt));
    rec(3, (u32)(nt * kt));
    rec(4, (u32)c_all(m, n, k));
    /* SHOT_CT counts the tile's strobe, so a digital-array build reports none.
     * The harness knows which build it is; this only records what it saw. */
    if ((wload1 - wload0) == (u32)(nt * kt) && c_all(m, n, k) &&
        ((shots1 - shots0) == (u32)(m * nt * kt) || (shots1 - shots0) == 0u))
        diag |= T2_OK;

    /* ---- T3: the tile is listening -------------------------------------- */
    wr(PHASE_ADDR, 5);
    {
        int moved = 0;
        wr(PTA_REG_IMPAIR, PTA_IMP_QUANT);
        wr(PTA_REG_BITS, PTA_BITS_FIELDS(0, 0, 4, 8));
        wr(PTA_REG_SEED, 1);
        if (!run_gemm(m, n, k)) {
            digital = 1;                 /* the array refuses every impairment */
            diag |= DIGITAL;
            wr(PTA_REG_IMPAIR, 0);
            wr(PTA_REG_BITS, 0);
            (void)run_gemm(m, n, k);     /* and the next valid start clears it */
        } else {
            moved = c_all(m, n, 0);
        }
        rec(5, (u32)moved);
        if (digital || moved) diag |= T3_OK;
    }

    /* ---- T4 and T5: a calibration, and a START during it ---------------- */
    wr(PHASE_ADDR, 6);
    if (!digital) {
        u32 ct0, ct1, st;
        int guard_ok = 0;
        int cal_amp;
        npu_drv_gemm_t g;
        /* Before the impairments: this uses MODEL_RST. */
        wr(PTA_REG_BITS, PTA_BITS_FIELDS(6, 5, 7, 8));
        cal_amp = cal_amp_find();
        rec(16, (u32)cal_amp);
        if (cal_amp < 2)
            cal_amp = 6;                 /* report the refusal rather than hide it */
        wr(PTA_REG_IMPAIR, PTA_IMP_QUANT | PTA_IMP_PROG_ERR | PTA_IMP_DRIFT);
        wr(PTA_REG_BITS, PTA_BITS_FIELDS(6, 5, 7, 8));
        wr(PTA_REG_SIGMA_PR, 0x0200);
        wr(PTA_REG_DRIFT, 0x00000200u);          /* sigma 2.0, a step every shot */
        wr(PTA_REG_DRIFT_MAX, 0x0C00);
        wr(PTA_REG_TRIM, PTA_TRIM_FIELDS(2, 0x2000));
        wr(PTA_REG_CAL_CFG, PTA_CAL_CFG_FIELDS(cal_amp, 0, 3, 0));
        wr(PTA_REG_CAL_SEED, 0x00CA11B0u);
        wr(PTA_REG_CAL_PER, 0);
        wr(PTA_REG_CTRL, PTA_CTRL_EN);           /* the engine, scheduler off */
        (void)run_gemm(m, n, k);                 /* let drift accumulate */

        ct0 = rd(PTA_REG_CAL_CT);
        wr(PTA_REG_CTRL, PTA_CTRL_EN | PTA_CTRL_CAL_NOW);

        /* The engine takes the tile when the core hands it an idle window, so
         * the calibration is not running the instant CAL_NOW is written.  A
         * bus master gets to its START a few cycles later and races it;
         * firmware needs a descriptor's worth of writes first, so wait for the
         * calibration to be under way -- otherwise the START lands after it and
         * the guard is not what is being tested. */
        {
            u32 spin = 0;
            while ((rd(PTA_REG_STATUS) & PTA_ST_CAL_BUSY) == 0 &&
                   ++spin < 20000u)
                ;
            if (spin >= 20000u)
                rec(17, 0xBADu);         /* it never started: say so */
        }

        /* The tile is calibrating, so this command has to queue.  Without the
         * guard it would dispatch into a tile that is not available, or vanish
         * and leave occupancy 0 with BUSY 0 -- which a driver reads as done. */
        g.dim_m = (u32)m; g.dim_n = (u32)n; g.dim_k = (u32)k;
        g.a_base = A_ADDR; g.b_base = B_ADDR; g.c_base = C_ADDR;
        g.prec = NPU_PREC_INT8;
        /* Nothing between CAL_NOW and this START but the descriptor: the
         * calibration has to still be running when it lands, or the guard is
         * not the thing being tested. */
        if (npu_drv_submit(&g) == 0) {
            st = rd(PTA_REG_STATUS);
            rec(6, st);
            rec(7, (u32)npu_drv_queue_occupancy());
            if ((st & PTA_ST_CAL_BUSY) != 0 && (st & PTA_ST_BUSY) == 0 &&
                npu_drv_queue_occupancy() == 1)
                guard_ok = 1;
        }
        if (npu_drv_drain(4000000ull) == 0 && guard_ok)
            diag |= T5_OK;

        while ((rd(PTA_REG_STATUS) & PTA_ST_CAL_BUSY) != 0)
            ;
        ct1 = rd(PTA_REG_CAL_CT);
        st  = rd(PTA_REG_STATUS);
        rec(8, ct1 - ct0);
        rec(9, st);
        rec(10, rd(PTA_REG_ERR_FOUND));
        rec(11, rd(PTA_REG_ERR_MAX));
        rec(12, rd(PTA_REG_CAL_CYC));
        if ((ct1 - ct0) == 1u && (st & PTA_ST_CAL_VALID) != 0 &&
            (st & PTA_ST_CAL_ERR) == 0 && rd(PTA_REG_ERR_FOUND) != 0u)
            diag |= T4_OK;
        wr(PTA_REG_CTRL, 0);
        wr(PTA_REG_IMPAIR, 0);
        wr(PTA_REG_BITS, 0);
    } else {
        diag |= T4_OK | T5_OK;      /* nothing to calibrate in a digital build */
    }

    /* ---- T7: a refusal, and that it clears ------------------------------ */
    wr(PHASE_ADDR, 7);
    {
        int refused, then_ran;
        u32 guard = 0;
        wr(PTA_REG_IMPAIR, PTA_IMP_MZM_NL);
        wr(NPU_REG_DIM_M, (u32)m);
        wr(NPU_REG_DIM_N, (u32)n);
        wr(NPU_REG_DIM_K, (u32)k);
        wr(NPU_REG_A_BASE, A_ADDR);
        wr(NPU_REG_B_BASE, B_ADDR);
        wr(NPU_REG_C_BASE, C_ADDR);
        wr(NPU_REG_PREC, NPU_PREC_INT8);
        wr(NPU_REG_CTRL, NPU_CTRL_START);
        /* The core refuses at the start, but STATUS.BUSY is the DMA's and it
         * takes the core's error through its own abort path, so wait. */
        while ((rd(NPU_REG_STATUS) & NPU_STATUS_BUSY) != 0 && guard++ < 100000u)
            ;
        refused = (rd(NPU_REG_STATUS) & NPU_STATUS_ERROR) != 0;
        wr(PTA_REG_IMPAIR, 0);
        then_ran = run_gemm(m, n, k) && c_all(m, n, k);
        rec(13, (u32)refused);
        rec(14, (u32)then_ran);
        if (refused && then_ran) diag |= T7_OK;
    }

    wr(PHASE_ADDR, 8);
    wr(DIAG_ADDR, diag);
    wr(RESULT_ADDR, (diag & (T1_OK | T2_OK | T3_OK | T4_OK | T5_OK | T6_OK | T7_OK)) ==
                    (T1_OK | T2_OK | T3_OK | T4_OK | T5_OK | T6_OK | T7_OK)
                    ? PASS_MAGIC : FAIL_MAGIC);
    wr(DONE_ADDR, DONE_MAGIC);
    for (;;)
        ;
}
