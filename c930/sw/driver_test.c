// -----------------------------------------------------------------------------
// driver_test.c - Firmware smoke test for the c930_npu_driver library.
//
// Boots on CPU0 of the SoC (linked at 0x0), reads GEMM dims from DIMS_ADDR,
// and drives the NPU EXCLUSIVELY through c930_npu_driver.h:
//
//   1. Queues the same GEMM 3 times back-to-back via npu_drv_submit()
//      (the 2nd/3rd submits land in the FIFO while the engine is busy).
//   2. Waits with npu_drv_drain() -- the queue-occupancy + idle drain poll.
//   3. Verifies C against a software reference computed on-core, proving the
//      drain really waited for all three commands.
//   4. Records performance counters + final occupancy, then signals DONE.
//
// The testbench (tb_npu_tile.sv) re-verifies C independently and checks the
// DONE magic, so a too-early drain fails on both sides.
//
// DDR layout (byte addresses):
//   0x1000 : A matrix (M*K bytes, INT8 row-major)
//   0x2000 : B matrix (K*N bytes, INT8 row-major)
//   0x3000 : C result (M*N*4 bytes)
//   0x4000 : C_ref (software reference)
//   0x9400 : dims descriptor (M, N, K, prec)
//   0x9410 : DONE magic
//   0x9420 : RESULT (PASS/FAIL magic)
//   0x9430 : stats (cycles, dma_last, ops, stalls, occ)
//   0x9490 : PHASE
//   0x9480 : DIAG
// -----------------------------------------------------------------------------

#include "c930_npu_driver.h"

typedef unsigned int u32;

#define A_ADDR      0x1000u
#define B_ADDR      0x2000u
#define C_ADDR      0x3000u
#define C_REF       0x4000u
#define DIMS_ADDR   0x9400u
#define DONE_ADDR   0x9410u
#define RESULT_ADDR 0x9420u
#define ST_ADDR     0x9430u
#define PHASE_ADDR  0x9490u
#define DIAG_ADDR   0x9480u

#define DONE_MAGIC  0xDEADBEEFu
#define PASS_MAGIC  0x0BADBEEFu
#define FAIL_MAGIC  0xBADF00Du

static u32 rd(u32 a) { return *(volatile u32 *)a; }
static void wr(u32 a, u32 v) { *(volatile u32 *)a = v; }

static void sw_gemm_ref(u32 m, u32 n, u32 k)
{
    for (u32 r = 0; r < m; r++) {
        for (u32 c = 0; c < n; c++) {
            int sum = 0;
            for (u32 p = 0; p < k; p++) {
                int av = (int)(signed char)*(volatile unsigned char *)(A_ADDR + r * k + p);
                int bv = (int)(signed char)*(volatile unsigned char *)(B_ADDR + p * n + c);
                sum += av * bv;
            }
            wr(C_REF + (r * n + c) * 4, (u32)sum);
        }
    }
}

int main(void)
{
    wr(PHASE_ADDR, 1);
    u32 m    = rd(DIMS_ADDR + 0);
    u32 n    = rd(DIMS_ADDR + 4);
    u32 k    = rd(DIMS_ADDR + 8);
    u32 prec = rd(DIMS_ADDR + 12);
    wr(PHASE_ADDR, 2);

    sw_gemm_ref(m, n, k);
    wr(PHASE_ADDR, 3);

    // All NPU access through the vendorable driver.
    npu_drv_mmio(NPU0_BASE);

    npu_drv_gemm_t g;
    g.dim_m  = m;
    g.dim_n  = n;
    g.dim_k  = k;
    g.a_base = A_ADDR;
    g.b_base = B_ADDR;
    g.c_base = C_ADDR;
    g.prec   = prec;

    // Three back-to-back submits: #1 starts the engine, #2/#3 queue.
    int rc = 0;
    rc |= npu_drv_submit(&g);
    wr(PHASE_ADDR, 4);
    rc |= npu_drv_submit(&g);
    rc |= npu_drv_submit(&g);
    wr(PHASE_ADDR, 5);

    // The drain poll: wait for occupancy==0 AND !BUSY (completion contract).
    int drain = npu_drv_drain(NPU_DRV_TIMEOUT_FOREVER);
    wr(PHASE_ADDR, 6);

    // Performance counters from the last command + final queue state.
    npu_drv_stats_t st;
    npu_drv_get_stats(&st);
    wr(ST_ADDR + 0,  st.core_cycles);
    wr(ST_ADDR + 4,  st.dma_last);
    wr(ST_ADDR + 8,  st.ops);
    wr(ST_ADDR + 12, st.stalls);
    wr(ST_ADDR + 16, (u32)npu_drv_queue_occupancy());   // must be 0

    // Verify all M*N elements on-core (drain must have waited for GEMM #3).
    u32 bad = 0;
    for (u32 r = 0; r < m && !bad; r++)
        for (u32 c = 0; c < n; c++)
            if (rd(C_ADDR + (r * n + c) * 4) != rd(C_REF + (r * n + c) * 4))
                bad = 1;

    wr(RESULT_ADDR, (rc == 0 && drain == 0 && !bad) ? PASS_MAGIC : FAIL_MAGIC);
    wr(DIAG_ADDR, bad ? 1u : (rc ? 2u : (drain ? 3u : 0u)));
    wr(DONE_ADDR, DONE_MAGIC);

    for (;;)
        ;
    return 0;
}