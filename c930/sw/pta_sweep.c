// ---------------------------------------------------------------------------
// pta_sweep.c -- C4(c): grxcp pta_cpu_integration.md section 6.2's sweep, run on
// the SoC from a RISC-V program through MMIO.
//
// Four points, each a (PTA_TW, PTA_TS) pair and a loop-order/residency mode.  For
// each one this sets the registers, runs a GEMM through the driver, and records
// what it cost: core cycles, the DMA's busy cycles, weight-movement cycles, shots
// and weight programmings.  Section 6.2 says DMA_CT is part of the result at the
// Pockels-class end, because a GEMM of a few thousand cycles is no longer long
// beside the fetch of its operands -- so it is recorded at every point, not just
// there, and the harness prints the feed's share.
//
// THE SHAPE IS THIS SoC'S, NOT SECTION 6.2'S.  The NPU here is MAX_M=8, MAX_K=16,
// MAX_N=12 and cannot be asked for M=64 N=8 K=256 at all -- the same gap section
// 6.1 records about its baseline.  What carries over from 6.2 is the points, which
// are ratios of Tw to Ts, not the shape they were tabulated at.  M=8 N=12 K=16
// gives two N tiles and two K tiles, so Nt*Kt is four, which is what this build's
// tile has resident; and its second N tile is four columns wide, so the sweep also
// crosses the ragged-tile case C2 found (Tw = nc*kr, not a flat 64).
//
// EO-res takes two GEMMs, and that is the point rather than a wart: the first
// fills the banks at the scan's usual cost, the second is the one measured.  What
// the resident regime claims is that the fill amortises across the GEMMs reusing
// it -- inference with fixed weights -- so both are recorded and the harness
// prints them side by side instead of quietly reporting the cheaper one.
//
// DDR map (the words this program owns; pta_test.c's layout, extended):
//   0x9400 : M, N, K, precision        0x9410 : DONE magic
//   0x9420 : RESULT (PASS/FAIL)        0x9480 : DIAG (a bit per point)
//   0x9490 : PHASE (progress, for a hang)
//   0x9500 : the sweep table, 8 words a point, five points (the fill is one)
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
#define SWEEP_ADDR  0x9500u

// The tile's shape, as pta_test.c also has to spell it: nothing in the register
// map reports it (the same gap section 3.3 records about DIN_W).
#define NUM_COLS    8
#define NUM_ROWS    8

#define DONE_MAGIC  0xDEADBEEFu
#define PASS_MAGIC  0x0BADBEEFu
#define FAIL_MAGIC  0x0BADF00Du

// One row of the table per point.  Eight words, so the harness can index it.
#define SW_CYCLES   0
#define SW_DMA_CT   1
#define SW_DMA_LAST 2
#define SW_STALL    3
#define SW_SHOTS    4
#define SW_WLOADS   5
#define SW_COK      6
#define SW_RAN      7

#define P_TO1MS     0
#define P_TO10US    1
#define P_EOSCAN    2
#define P_EORES_FIL 3
#define P_EORES     4
#define N_POINTS    5

// DDR is flat and identity-mapped for this program, and the addresses above are
// absolute -- the same idiom pta_test.c uses.  Indexing from a null base would be
// pointer arithmetic on null, which happens to work and is still not written here.
static u32  rd(u32 a)        { return *(volatile u32 *)a; }
static void wr(u32 a, u32 v) { *(volatile u32 *)a = v; }

static void sw_put(int p, int slot, u32 v)
{
    wr(SWEEP_ADDR + 32u * (u32)p + 4u * (u32)slot, v);
}

static int ceil_div(int a, int b) { return (a + b - 1) / b; }

// One GEMM through the driver.  Returns 0 if the engine refused it; drain is a
// status code, not a predicate, which is the mistake pta_test.c records.
// C is READ-ONLY from the CPU, and each point writes its own block.
//
// The L2 records a sharer only on a read fill and is write-through/no-allocate, so
// a line the CPU has written leaves the directory and a later DMA write
// invalidates nobody (CPU document 3.3, found at C4(a)).  Clearing C from firmware
// would therefore make every readback stale.  Reading it is safe the first time --
// the line is fetched fresh -- but only the first time, so a point reusing an
// earlier point's C would be checking the earlier point's arithmetic.  Each point
// gets its own C block, which keeps every check a real one.
static u32 c_base_of(int p) { return C_ADDR + 0x200u * (u32)p; }

// Returns 1 on success, or a negative code saying which step failed, so a point
// that does not run says why instead of leaving zeros behind.
#define G_SUBMIT  (-1)
#define G_DRAIN   (-2)
#define G_ERROR   (-3)
static int run_gemm(int p, int m, int n, int k)
{
    npu_drv_gemm_t g;
    g.dim_m = (u32)m; g.dim_n = (u32)n; g.dim_k = (u32)k;
    g.a_base = A_ADDR; g.b_base = B_ADDR; g.c_base = c_base_of(p);
    g.prec = NPU_PREC_INT8;
    if (npu_drv_submit(&g) != 0)
        return G_SUBMIT;
    if (npu_drv_drain(20000000ull) != 0)
        return G_DRAIN;
    return npu_drv_error() ? G_ERROR : 1;
}

// Every operand is 1, so every C element is exactly K with the model off.  A
// wrong bank select shows up here before it shows up in a cycle count.
static int c_exact(int p, int m, int n, int k)
{
    int i;
    for (i = 0; i < m * n; i++)
        if (rd(c_base_of(p) + 4u * (u32)i) != (u32)k)
            return 0;
    return 1;
}

// Run one point and record it.  `modes` are the PTA_CTRL bits MB added.
static int point(int p, int m, int n, int k, u32 tw, u32 ts, u32 modes)
{
    u32 shots0, wloads0, ran;

    wr(PHASE_ADDR, 0x10u + (u32)p);
    wr(PTA_REG_TW, tw);
    wr(PTA_REG_TS, ts);
    // The engine stays off: this sweep is about the loop nest's cost, and a
    // calibration inside a point would add its own cycles to the total.
    wr(PTA_REG_CTRL, modes);

    shots0  = rd(PTA_REG_SHOT_CT);
    wloads0 = rd(PTA_REG_WLOAD_CT);

    ran = (u32)run_gemm(p, m, n, k);
    sw_put(p, SW_RAN, ran);
    if ((int)ran != 1)
        return 0;

    sw_put(p, SW_CYCLES,   rd(NPU_REG_CYCLE_LO));
    sw_put(p, SW_DMA_CT,   rd(NPU_REG_DMA_CT));
    sw_put(p, SW_DMA_LAST, rd(NPU_REG_DMA_LAST));
    sw_put(p, SW_STALL,    rd(NPU_REG_STALL_CT));
    sw_put(p, SW_SHOTS,    rd(PTA_REG_SHOT_CT) - shots0);
    sw_put(p, SW_WLOADS,   rd(PTA_REG_WLOAD_CT) - wloads0);
    sw_put(p, SW_COK,      (u32)c_exact(p, m, n, k));
    return 1;
}

int main(void)
{
    int m, n, k, nt, kt, p;
    u32 diag = 0;

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

    // The two thermo-optic points and the scanned Pockels one: the shipped
    // behaviour, one bank per compute, scanned every tile.
    if (point(P_TO1MS,  m, n, k, 100000u, 5u, 0u)) diag |= 1u << P_TO1MS;
    if (point(P_TO10US, m, n, k,   1000u, 5u, 0u)) diag |= 1u << P_TO10US;
    if (point(P_EOSCAN, m, n, k,      0u, 1u, 0u)) diag |= 1u << P_EOSCAN;

    // EO-res.  The fill writes every (N tile, K tile) to its own bank at the
    // scan's usual cost; the measured GEMM then finds them there.
    if (point(P_EORES_FIL, m, n, k, 0u, 1u, PTA_CTRL_RESIDENT))
        diag |= 1u << P_EORES_FIL;
    if (point(P_EORES, m, n, k, 0u, 1u, PTA_CTRL_RESIDENT | PTA_CTRL_WSKIP))
        diag |= 1u << P_EORES;

    // What the shape was, so the harness does not have to assume it.
    wr(SWEEP_ADDR + 32u * N_POINTS + 0u, (u32)nt);
    wr(SWEEP_ADDR + 32u * N_POINTS + 4u, (u32)kt);

    // Every point ran and every one returned the right C.
    {
        int all = 1;
        for (p = 0; p < N_POINTS; p++) {
            if (!(diag & (1u << p))) all = 0;
            if (rd(SWEEP_ADDR + 32u * (u32)p + 4u * SW_COK) != 1u) all = 0;
        }
        wr(RESULT_ADDR, all ? PASS_MAGIC : FAIL_MAGIC);
    }

    wr(DIAG_ADDR, diag);
    wr(PHASE_ADDR, 0xFFu);
    wr(DONE_ADDR, DONE_MAGIC);
    for (;;) { }
}
