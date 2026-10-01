// tb_soc4.cc -- Verilator harness for the FULL 4-core SoC with the shared
// L2 cache ACTIVE (the path Icarus cannot simulate at usable speed).
//
// Modes (argv[1]):
//   (none) / "quad" : mirrors tb_quad_isolated.sv -- preloads the quadcore
//                     DDR image + operands, boots all 4 harts, waits for
//                     CPU0 to write the 0xFACEFEED magic to DDR[0x9400].
//   "pta"           : phase C4(a) -- boots sw/pta_test.c, which configures
//                     the PTA register block at 0x4000_0100 through MMIO and
//                     checks seven things, and reports the bitmap it wrote.
//   "suite"         : mirrors Test 4 of tb_c930_soc_full.sv -- the
//                     "full-SoC NPU firmware suite": boots CPU0 firmware
//                     (tb4_phase1_fw.hex) that queues 4 mixed-precision
//                     GEMMs through the MMIO queue and drains it, writes
//                     0xDEADBEEF at DDR[0xB300]; then reloads the
//                     verification firmware (tb4_phase2_fw.hex), reboots,
//                     and checks the firmware's per-GEMM error masks at
//                     DDR[0x300/0x308/0x310/0x318] are all zero (all C
//                     elements read back through the CPU D-cache + L2).
//   "sweep"         : C4(c) -- boots sw/pta_sweep.c, which runs section 6.2's
//                     points through MMIO and records what each cost.
//   "feed"          : F2 -- boots sw/pta_feed.c, which measures the feed's
//                     options at the two Pockels points. Wants PTM_B=1: on
//                     PTM-C the drain hides the fetch and the options converge.
//   "l2coh"         : the L2 directory's blind spot, as a test.
//   "mulstore"      : a multiply retiring while a store sits in MEM.
//   "driver"        : the NPU driver's own smoke test.
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include "Vc930_soc4_verilator.h"
#include "Vc930_soc4_verilator___024root.h"
#include "verilated.h"

static const int MEM_BYTES = 65536;

static inline uint8_t ddr_byte(Vc930_soc4_verilator *top, uint32_t addr) {
    top->i_tb_rd_addr = addr & (MEM_BYTES-1);
    top->eval();
    return top->o_tb_rd_data;
}
static inline uint32_t ddr_word(Vc930_soc4_verilator *top, uint32_t addr) {
    return (uint32_t)ddr_byte(top, addr) |
           ((uint32_t)ddr_byte(top, addr+1) << 8) |
           ((uint32_t)ddr_byte(top, addr+2) << 16) |
           ((uint32_t)ddr_byte(top, addr+3) << 24);
}

// Write one byte through the clocked TB preload port.
static void preload_byte(Vc930_soc4_verilator *top, uint32_t addr, uint8_t data) {
    top->i_tb_wr_en   = 1;
    top->i_tb_wr_addr = addr;
    top->i_tb_wr_data = data;
    top->i_clk = 0; top->eval();
    top->i_clk = 1; top->eval();
    top->i_tb_wr_en = 0;
    top->i_clk = 0; top->eval();
    top->i_clk = 1; top->eval();
}
static void preload_word(Vc930_soc4_verilator *top, uint32_t addr, uint32_t val) {
    preload_byte(top, addr+0, (uint8_t)(val));
    preload_byte(top, addr+1, (uint8_t)(val >> 8));
    preload_byte(top, addr+2, (uint8_t)(val >> 16));
    preload_byte(top, addr+3, (uint8_t)(val >> 24));
}

// Parse a 2-hex-digit-per-token byte hex file and write it via the TB
// preload port starting at DDR address 'base'.
static void preload_hex_at(Vc930_soc4_verilator *top, const char *fname,
                           uint32_t base, uint32_t limit) {
    FILE *f = fopen(fname, "r");
    if (!f) { fprintf(stderr, "[TB] cannot open %s\n", fname); exit(2); }
    uint32_t a = 0;
    unsigned b;
    while (a < limit && fscanf(f, "%2x", &b) == 1) {
        preload_byte(top, base + a, (uint8_t)b);
        a++;
    }
    fclose(f);
    printf("[TB] loaded %u bytes from %s at DDR[0x%05x]\n", a, fname, base);
}

// The same, for a file of 32-bit words (one 8-digit token a line, which is what
// sw/bin2hex.py emits and what the iverilog benches $readmemh into a word
// array).  The byte-hex reader above is for the Test-4 images, which are bytes.
static void preload_words_at(Vc930_soc4_verilator *top, const char *fname,
                             uint32_t base, uint32_t limit_bytes) {
    FILE *f = fopen(fname, "r");
    if (!f) { fprintf(stderr, "[TB] cannot open %s\n", fname); exit(2); }
    uint32_t a = 0;
    unsigned w;
    while (a < limit_bytes && fscanf(f, "%8x", &w) == 1) {
        preload_word(top, base + a, (uint32_t)w);
        a += 4;
    }
    fclose(f);
    printf("[TB] loaded %u bytes (%u words) from %s at DDR[0x%05x]\n",
           a, a / 4, fname, base);
}

static void clock_n(Vc930_soc4_verilator *top, int n) {
    for (int i = 0; i < n; i++) {
        top->i_clk = 0; top->eval();
        top->i_clk = 1; top->eval();
    }
}

// Assert reset low, hold, then release.
static void reset_release(Vc930_soc4_verilator *top) {
    top->i_rst_n = 0;
    clock_n(top, 10);
    top->i_rst_n = 1;
    top->i_clk = 0; top->eval();
}

// Poll a DDR location for a magic value.  Returns cycles waited or -1.
// When trace_early>0, dumps CSR/DMA state every cycle in the first
// trace_early cycles (for bring-up of new flows).
static int wait_magic(Vc930_soc4_verilator *top, uint32_t addr, uint32_t magic,
                      int max_cyc, const char *label, int trace_early) {
    for (int c = 0; c < max_cyc; c++) {
        clock_n(top, 1);
        if (trace_early > 0 && c >= 900 && c <= 2400)
            printf("[TR] %s cyc %d: dma=%d/%d/%d/%d ic=%d(%03x)/ics=%d adp=%d m0_ar=%d/%d m0_rv=%d/%d l2rd=%d xr=%d/%d npu_b=%d pc0=%08llx arb=%d/%d/%d sav=%d/%d npu1_av=%d dma1=%d pf=%d/%d wr=%d rs=%d l2wr=%d war=%d xw=%d aw=%d/%d w=%d/%d bv=%d\n",
                   label, c, (int)top->o_dma0_phase, (int)top->o_csr0_disp,
                   (int)top->o_csr0_fifo, (int)top->o_csr0_done_latch,
                   (int)top->o_ic0_state, (int)top->o_ic0_fill, (int)top->o_ic0_stall,
                   (int)top->o_icadp_state,
                   (int)top->o_m0_arvalid, (int)top->o_m0_arready,
                   (int)top->o_m0_rvalid, (int)top->o_m0_rready,
                   (int)top->o_l2_rd_cur,
                   (int)top->o_xbar_r_state, (int)top->o_xbar_r_grant,
                   (int)top->o_npu0_busy, (unsigned long long)top->o_hart0_pc,
                   (int)top->o_arb_rd_owner, (int)top->o_arb_rd_active,
                   (int)top->o_arb_rd_addr_phase,
                   (int)top->o_arb_s_arvalid, (int)top->o_arb_s_arready,
                   (int)top->o_npu1_arvalid, (int)top->o_dma1_phase,
                   (int)top->o_dma0_pf, (int)top->o_dma0_pf2,
                   (int)top->o_dma0_wr_sub, (int)top->o_dma0_rdsub,
                   (int)top->o_l2_wr_state, (int)top->o_arb_wr_active,
                   (int)top->o_xbar_w_state, (int)top->o_l2_s_awvalid,
                   (int)top->o_l2_s_awready, (int)top->o_l2_s_wvalid,
                   (int)top->o_l2_s_wready, (int)top->o_l2_s_bvalid);
            printf("[TB] %s: cyc %d l2_rd=%d dma_ph=%d npu_b=%d npu_d=%d pc0=0x%08llx dc0=%d dcs=%d ic0=%d ics=%d l2wr=%d wr=%d aw=%d/%d w=%d/%d b=%d/%d wlf=%d war=%d/%d/%d xw=%d/%d maw=%d/%d mw=%d/%d mb=%d/%d\n", label,
                   c, (int)top->o_l2_rd_state, (int)top->o_dma0_phase,
                   (int)top->o_npu0_busy, (int)top->o_npu0_done,
                   (unsigned long long)top->o_hart0_pc,
                   (int)top->o_dc0_state, (int)top->o_dc0_stall,
                   (int)top->o_ic0_state, (int)top->o_ic0_stall,
                   (int)top->o_l2_wr_state, (int)top->o_dma0_wr_sub,
                   (int)top->o_l2_s_awvalid, (int)top->o_l2_s_awready,
                   (int)top->o_l2_s_wvalid, (int)top->o_l2_s_wready,
                   (int)top->o_l2_s_bvalid, (int)top->o_l2_s_bready,
                   (int)top->o_l2_wrlog_full,
                   (int)top->o_arb_wr_owner, (int)top->o_arb_wr_active,
                   (int)top->o_arb_wr_addr_phase,
                   (int)top->o_xbar_w_state, (int)top->o_xbar_w_grant,
                   (int)top->o_l2_m_awvalid, (int)top->o_l2_m_awready,
                   (int)top->o_l2_m_wvalid, (int)top->o_l2_m_wready,
                   (int)top->o_l2_m_bvalid, (int)top->o_l2_m_bready);
        if (ddr_word(top, addr) == magic) {
            printf("[TB] %s: magic 0x%08x at DDR[0x%05x] after %d cycles\n",
                   label, magic, addr, c);
            return c;
        }
    }
    printf("[TB] %s: TIMEOUT after %d cycles (magic=0x%08x)\n",
           label, max_cyc, ddr_word(top, addr));
    return -1;
}
// ---------------------------------------------------------------------------
// Quadcore mode (default) -- mirrors tb_quad_isolated.sv
// ---------------------------------------------------------------------------
static int run_quad(Vc930_soc4_verilator *top) {
    printf("[TB] 4-core SoC (L2 ACTIVE) Verilator model -- QUAD mode\n");

    top->i_rst_n = 0;
    top->i_tb_wr_en = 0;
    top->i_clk = 0; top->eval();

    preload_hex_at(top, "sw/quadcore_ddr_bytes.hex", 0, MEM_BYTES);
    for (int i = 0; i < 16; i++) { preload_byte(top, 0x8000+i, 0x01); preload_byte(top, 0x8400+i, 0x01); }
    for (int i = 0; i < 9;  i++) { preload_byte(top, 0xA000+i, 0x02); preload_byte(top, 0xA400+i, 0x02); }
    for (int i = 0; i < 9;  i++) { preload_byte(top, 0xB000+i, 0x03); preload_byte(top, 0xB400+i, 0x03); }
    for (int i = 0; i < 16; i++) { preload_byte(top, 0xD000+i, 0x04); preload_byte(top, 0xD400+i, 0x04); }
    for (int i = 0; i < 1280; i++) preload_byte(top, 0x9000+i, 0x00);

    printf("[TB] DDR preloaded. Releasing reset.\n");
    reset_release(top);

    int cyc = wait_magic(top, 0x9400, 0xFACEFEED, 2000000, "quad", 0);
    if (cyc < 0) return 1;

    for (int c = 0; c < 4; c++) {
        uint32_t h = 0x9000 + c*256;
        printf("[TB] hart %d: hartid=0x%08x errmask=0x%08x phase=0x%08x\n", c,
               ddr_word(top, h), ddr_word(top, h+4), ddr_word(top, h+8));
    }
    printf("[TB] PASS: quadcore 0xFACEFEED after %d cycles\n", cyc);
    return 0;
}

// ---------------------------------------------------------------------------
// Suite mode -- mirrors Test 4 of tb_c930_soc_full.sv
// ---------------------------------------------------------------------------
static int run_suite(Vc930_soc4_verilator *top) {
    printf("[TB] 4-core SoC (L2 ACTIVE) Verilator model -- SUITE mode "
           "(full-SoC NPU firmware suite)\n");

    top->i_rst_n = 0;
    top->i_tb_wr_en = 0;
    top->i_clk = 0; top->eval();

    // ---- DDR image (mirrors the SV TB's preloads in Test 4) ----
    // Phase-1 firmware: CPU0 queues 4 mixed-precision GEMMs via MMIO.
    preload_hex_at(top, "sw/tb4_phase1_fw.hex", 0x0000, 512);

    // GEMM0 operands (INT8 3x5x8, all 1): A@0x8000 (24B), B@0x8200 (40B)
    for (int i = 0; i < 24; i++) preload_byte(top, 0x8000 + i, 1);
    for (int i = 0; i < 40; i++) preload_byte(top, 0x8200 + i, 1);
    // GEMM1 operands (FP16 7x3x8, all 1.0 = 0x3C00, 2B LE): A@0x8800 (112B), B@0x8A00 (48B)
    for (int i = 0; i < 56; i++) { preload_byte(top, 0x8800 + i*2 + 0, 0x00); preload_byte(top, 0x8800 + i*2 + 1, 0x3C); }
    for (int i = 0; i < 24; i++) { preload_byte(top, 0x8A00 + i*2 + 0, 0x00); preload_byte(top, 0x8A00 + i*2 + 1, 0x3C); }
    // GEMM2 operands (BF16 2x12x8, all 1.0 = 0x3F80, 2B LE): A@0x9000 (32B), B@0x9200 (192B)
    for (int i = 0; i < 16; i++) { preload_byte(top, 0x9000 + i*2 + 0, 0x80); preload_byte(top, 0x9000 + i*2 + 1, 0x3F); }
    for (int i = 0; i < 96; i++) { preload_byte(top, 0x9200 + i*2 + 0, 0x80); preload_byte(top, 0x9200 + i*2 + 1, 0x3F); }
    // GEMM3 operands (INT4 3x4x5, signed nibble pattern): A@0xA000 (8B), B@0xA200 (10B)
    const uint8_t g3a[8]  = {0xE1,0xC3,0xB5,0xD4,0xF2,0xF2,0xD4,0x01};
    const uint8_t g3b[10] = {0xF1,0xE2,0x1E,0x2F,0xE3,0xF1,0x3F,0x1E,0x1E,0x2D};
    for (int i = 0; i < 8;  i++) preload_byte(top, 0xA000 + i, g3a[i]);
    for (int i = 0; i < 10; i++) preload_byte(top, 0xA200 + i, g3b[i]);

    // Expected C tables used by the phase-2 verification firmware:
    //   GEMM0: 15 x 0x08 (INT32 8) @ 0xB100
    //   GEMM2: 24 x 0x41000000 (FP32 8.0) @ 0xB200
    //   GEMM3: 12 unique INT32 words @ 0xB000
    for (int i = 0; i < 15; i++) preload_word(top, 0xB100 + i*4, 0x00000008);
    for (int i = 0; i < 24; i++) preload_word(top, 0xB200 + i*4, 0x41000000);
    const uint32_t g3exp[12] = {
        0x00000008,0xFFFFFFF0,0x00000000,0xFFFFFFFD,
        0xFFFFFFEA,0x00000014,0xFFFFFFEE,0x00000015,
        0x00000011,0xFFFFFFED,0x0000000C,0xFFFFFFF5};
    for (int i = 0; i < 12; i++) preload_word(top, 0xB000 + i*4, g3exp[i]);

    // Clear DONE + verify buffers
    for (int i = 0; i < 4; i++) { preload_byte(top, 0xB300+i, 0); }
    for (int i = 0; i < 32; i++) preload_byte(top, 0x300 + i, 0);

    printf("[TB] Phase-1 image preloaded. Booting CPU0 firmware.\n");
    reset_release(top);

    int c1 = wait_magic(top, 0xB300, 0xDEADBEEF, 3000000, "suite-p1", 60000);
    if (c1 < 0) return 1;
    printf("[TB] PASS phase 1: 4 GEMMs queued & drained (%d cycles)\n", c1);

    // ---- Phase 2: reload verification firmware, reboot CPU0 ----
    // The DDR content (operands + C results written by the NPU DMA) is
    // preserved; only the firmware image at 0x0000 is replaced.  The full
    // SoC reset (below) flushes L1 + L2 so the reboot fetches the new code.
    top->i_rst_n = 0;               // assert reset first
    top->i_clk = 0; top->eval();
    preload_hex_at(top, "sw/tb4_phase2_fw.hex", 0x0000, 512);
    for (int i = 0; i < 4; i++) preload_byte(top, 0xB300+i, 0);   // clear DONE
    for (int i = 0; i < 32; i++) preload_byte(top, 0x300 + i, 0); // clear verify
    printf("[TB] Phase-2 image preloaded. Rebooting CPU0 verification firmware.\n");
    reset_release(top);

    int c2 = wait_magic(top, 0xB300, 0xDEADBEEF, 3000000, "suite-p2", 30000);
    if (c2 < 0) return 1;
    printf("[TB] PASS phase 2: verification firmware done (%d cycles)\n", c2);

    // ---- Check the verification error masks (must all be zero) ----
    // GEMM1 mask @0x300 (21 elems), GEMM3 @0x308 (12), GEMM0 @0x310 (15),
    // GEMM2 @0x318 (24).  The firmware also stores the element counts at
    // mask+4, which we verify as a cross-check.
    struct { uint32_t addr; const char* name; uint32_t n; } vf[4] = {
        {0x300, "GEMM1 FP16 7x3x8", 21},
        {0x308, "GEMM3 INT4 3x4x5", 12},
        {0x310, "GEMM0 INT8 3x5x8", 15},
        {0x318, "GEMM2 BF16 2x12x8", 24},
    };
    int errs = 0;
    for (int i = 0; i < 4; i++) {
        uint32_t mask = ddr_word(top, vf[i].addr);
        uint32_t cnt  = ddr_word(top, vf[i].addr + 4);
        bool ok = (mask == 0) && (cnt == vf[i].n);
        printf("[TB] %s: err_mask=0x%08x count=%u -> %s\n", vf[i].name,
               mask, cnt, ok ? "OK" : "FAIL");
        if (!ok) errs++;
    }
    if (errs == 0) {
        printf("[TB] PASS: full-SoC NPU firmware suite -- all C verified "
               "through D-cache + L2 (%d + %d cycles)\n", c1, c2);
        return 0;
    }
    printf("[TB] FAIL: %d GEMM verification masks non-zero\n", errs);
    return 1;
}


// ---------------------------------------------------------------------------
// PTA mode (phase C4(a)): the PTA register block, driven by firmware.
//
// sw/pta_test.c configures the tile through the block at 0x4000_0100 and checks
// seven things, writing a bitmap to DIAG.  The operands are all ones, so C is K
// everywhere with nothing impaired and the firmware needs no reference of its
// own.  This harness supplies them, boots CPU0 and reports what the firmware
// found -- and insists on which build it is looking at, since a firmware pass
// would mean nothing otherwise.
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// C4(c): section 6.2's sweep, run on the SoC by sw/pta_sweep.c
// ---------------------------------------------------------------------------
// The firmware drives the points through MMIO and leaves a table in DDR; this
// reads it and checks the two things the plan asks of C4(c): that every point ran
// and returned the right C, and that EO-res is measured rather than modelled.
//
// The shape is the SoC's.  This NPU is MAX_M=8, MAX_K=16, MAX_N=12 and cannot be
// asked for section 6.2's M=64 N=8 K=256 at all -- the same gap section 6.1 records
// about its baseline -- so what carries over is the points, which are ratios, and
// not the shape they were tabulated at.  Said in the output too, because a cycle
// count with the wrong shape attached to it is worse than no cycle count.
// ---------------------------------------------------------------------------
// The L2 directory's blind spot (sw/l2_coh_test.c)
// ---------------------------------------------------------------------------
// A line the CPU has written is outside c930_l2.sv's directory: a write is
// write-through with no allocate, so the L2 invalidates the sharers it knows of
// except the writer and then drops the line -- valid and sharers both cleared.
// A later write by anyone else finds it not resident and invalidates nobody, and
// the CPU keeps its stale copy.  The rule "firmware must not write a buffer the
// accelerator writes" has lived in comments in two firmwares since C4(a); this
// turns it into a test.
static int run_l2coh(Vc930_soc4_verilator *top) {
    const int M = 8, N = 8, K = 16;
    const uint32_t A = 0x1000, B = 0x2000;
    const uint32_t C1 = 0x3000, C2 = 0x3400, C3 = 0x3800;
    const uint32_t DIMS = 0x9400, DONE = 0x9410, RESULT = 0x9420;
    const uint32_t REC = 0x9430, DIAG = 0x9480, PHASE = 0x9490;
    const uint32_t PASS_MAGIC = 0x0BADBEEF;

    printf("[TB] 4-core SoC -- the L2 directory's blind spot, driven by firmware\n");
    printf("[TB] every operand is 1, so every C element should read back as K=%d\n", K);

    top->i_rst_n = 0;
    top->i_tb_wr_en = 0;
    top->i_clk = 0; top->eval();

    const char *fw = getenv("PTA_FW");
    preload_words_at(top, fw ? fw : "sw/l2_coh_prog.hex", 0x0000, 8192);

    for (int i = 0; i < M * K; i++) preload_byte(top, A + i, 1);
    for (int i = 0; i < K * N; i++) preload_byte(top, B + i, 1);
    for (uint32_t base : { C1, C2, C3 })
        for (int i = 0; i < M * N; i++) preload_word(top, base + i * 4, 0);
    preload_word(top, DIMS + 0, (uint32_t)M);
    preload_word(top, DIMS + 4, (uint32_t)N);
    preload_word(top, DIMS + 8, (uint32_t)K);
    preload_word(top, DIMS + 12, 0);
    preload_word(top, DONE, 0);
    preload_word(top, RESULT, 0);
    preload_word(top, DIAG, 0);
    preload_word(top, PHASE, 0);
    for (int i = 0; i < 16; i++) preload_word(top, REC + i * 4, 0);

    reset_release(top);

    int c = -1;
    for (int t = 0; t < 8000000; t++) {
        clock_n(top, 1);
        if ((t % 1000000) == 0)
            printf("[TB]   t=%-8d pc=0x%08llx npu=%d/%d phase=%u\n", t,
                   (unsigned long long)top->o_hart0_pc, (int)top->o_npu0_busy,
                   (int)top->o_npu0_done, ddr_word(top, PHASE));
        if (ddr_word(top, DONE) == 0xDEADBEEF) { c = t; break; }
    }
    if (c < 0) {
        printf("[TB] l2coh: TIMEOUT, PHASE=%u\n", ddr_word(top, PHASE));
        return 1;
    }
    printf("[TB] l2coh: done after %d cycles\n", c);

    const uint32_t diag = ddr_word(top, DIAG);
    const uint32_t res  = ddr_word(top, RESULT);
    const uint32_t total = ddr_word(top, REC + 12);
    struct Row { uint32_t bit; int good_slot, bad_slot; const char *what; };
    const Row rows[3] = {
        { 0x002, 4, 5, "T2 control: C untouched by the CPU before the GEMM" },
        { 0x004, 7, 8, "T3 a line the CPU READ is invalidated" },
        { 0x001, 0, 1, "T1 a line the CPU WROTE is invalidated" },
    };
    int fails = 0;
    for (const Row& r : rows) {
        const bool ok = (diag & r.bit) != 0;
        const uint32_t good = ddr_word(top, REC + 4 * r.good_slot);
        const uint32_t bad  = ddr_word(top, REC + 4 * r.bad_slot);
        printf("[TB]   %s %s -- %u/%u elements right", ok ? "[PASS]" : "[FAIL]",
               r.what, good, total);
        if (!ok) {
            ++fails;
            if (bad == 0x0BADC0DE)
                printf(", and the first wrong one held the CPU's own poison:"
                       " the stale L1 line was never invalidated");
            else
                printf(", first wrong value 0x%08x -- not the poison, so this is"
                       " not the directory", bad);
        }
        printf("\n");
    }
    if (res != PASS_MAGIC && fails == 0) {
        printf("[TB]   [FAIL] RESULT is not PASS\n");
        ++fails;
    }
    if (fails) {
        printf("[TB] FAIL: %d check(s)\n", fails);
        return 1;
    }
    printf("[TB] PASS: the directory tracks a line the CPU wrote\n");
    return 0;
}

static int run_sweep(Vc930_soc4_verilator *top) {
    const int M = 8, N = 12, K = 16;     // 2 N tiles (8 and 4 wide), 2 K tiles
    const uint32_t A = 0x1000, B = 0x2000, C = 0x3000;
    const uint32_t DIMS = 0x9400, DONE = 0x9410, RESULT = 0x9420;
    const uint32_t DIAG = 0x9480, PHASE = 0x9490, SWEEP = 0x9500;
    const uint32_t PASS_MAGIC = 0x0BADBEEF;
    // Five named points, then PTA_TS swept at EO-scan's other settings.
    const int NAMED = 5, NTS = 5, NPTS = NAMED + NTS, STRIDE = 16;
    const uint32_t TS_LIST[NTS] = { 1, 2, 4, 8, 16 };

    printf("[TB] 4-core SoC -- C4(c): section 6.2's sweep, driven by firmware\n");
    printf("[TB] shape M=%d N=%d K=%d: this SoC's NPU, not 6.2's -- MAX_M=8, "
           "MAX_K=16, MAX_N=12 cannot be asked for M=64 N=8 K=256 (6.1)\n",
           M, N, K);

    top->i_rst_n = 0;
    top->i_tb_wr_en = 0;
    top->i_clk = 0; top->eval();

    const char *fw = getenv("PTA_FW");
    preload_words_at(top, fw ? fw : "sw/pta_sweep_prog.hex", 0x0000, 8192);

    for (int i = 0; i < M * K; i++) preload_byte(top, A + i, 1);
    for (int i = 0; i < K * N; i++) preload_byte(top, B + i, 1);
    // A C block per point, 0x200 apart.  The firmware never writes C from the
    // CPU -- the L2 stops tracking a line the CPU wrote, so the DMA's write
    // would not invalidate it -- and a point reusing an earlier point's C
    // would be checking the earlier point's arithmetic.
    for (int p = 0; p < NPTS; p++)
        for (int i = 0; i < M * N; i++)
            preload_word(top, C + 0x200 * p + i * 4, 0);
    preload_word(top, DIMS + 0, (uint32_t)M);
    preload_word(top, DIMS + 4, (uint32_t)N);
    preload_word(top, DIMS + 8, (uint32_t)K);
    preload_word(top, DIMS + 12, 0);
    preload_word(top, DONE, 0);
    preload_word(top, RESULT, 0);
    preload_word(top, DIAG, 0);
    preload_word(top, PHASE, 0);
    for (int i = 0; i < STRIDE * (NPTS + 1); i++)
        preload_word(top, SWEEP + i * 4, 0);

    printf("[TB] image preloaded, all operands 1 so every C element is K=%d. "
           "Booting CPU0.\n", K);
    reset_release(top);

    // TO-1ms alone is Nt*Kt * 100,000 cycles of settle, so this runs longer than
    // the other firmware modes by an order of magnitude.
    int c = -1;
    for (int t = 0; t < 20000000; t++) {
        clock_n(top, 1);
        if ((t % 2000000) == 0 || t == 20000000 - 1)
            printf("[TB]   t=%-9d pc=0x%08llx npu=%d/%d dma=%d phase=0x%02x\n",
                   t, (unsigned long long)top->o_hart0_pc,
                   (int)top->o_npu0_busy, (int)top->o_npu0_done,
                   (int)top->o_dma0_phase, ddr_word(top, PHASE));
        if (ddr_word(top, DONE) == 0xDEADBEEF) { c = t; break; }
    }
    if (c >= 0) printf("[TB] sweep: done after %d cycles\n", c);
    else {
        printf("[TB] sweep: TIMEOUT after 20000000 cycles, PHASE=0x%02x\n",
               ddr_word(top, PHASE));
        return 1;
    }

    struct Row { const char *name; const char *what; };
    const Row rows[NPTS] = {
        { "TO-1ms ",      "thermo-optic, 1 ms settle"      },
        { "TO-10us",      "thermo-optic, 10 us settle"     },
        { "EO-scan",      "Pockels, scanned"               },
        { "EO-res fill",  "Pockels, resident: the fill"    },
        { "EO-res ",      "Pockels, resident: measured"    },
        { "TS=1",  "" }, { "TS=2",  "" }, { "TS=4",  "" },
        { "TS=8",  "" }, { "TS=16", "" },
    };
    auto slot = [&](int p, int i) {
        return ddr_word(top, SWEEP + 4u * STRIDE * (uint32_t)p + 4u * (uint32_t)i);
    };

    const uint32_t nt = ddr_word(top, SWEEP + 4u * STRIDE * NPTS + 0);
    const uint32_t kt = ddr_word(top, SWEEP + 4u * STRIDE * NPTS + 4);
    printf("[TB]   Nt=%u Kt=%u, so Nt*Kt=%u weight banks resident at EO-res\n",
           nt, kt, nt * kt);
    printf("[TB]   %-12s %-9s %-9s %-8s %-7s %-7s %-7s %-6s %s\n",
           "point", "cycles", "DMA busy", "wmove", "A-row", "shots",
           "progs", "C", "feed/core");

    int bad = 0;
    for (int p = 0; p < NAMED; p++) {
        const uint32_t cyc = slot(p, 0), dma = slot(p, 1), wmove = slot(p, 3);
        // Absolute readings; the first point's own delta is against zero,
        // since nothing has run before it.
        const uint32_t shots = slot(p, 4) - (p ? slot(p - 1, 4) : 0);
        const uint32_t progs = slot(p, 5) - (p ? slot(p - 1, 5) : 0);
        const uint32_t cok = slot(p, 6);
        const int      ran = (int)slot(p, 7);
        // DMA_CT counts every cycle with phase != P_IDLE, and P_LAUNCH -- the
        // core's whole compute -- is one of those phases.  So DMA busy is the
        // GEMM, from the first AR to o_done, not the fetch, and the fetch is
        // the difference.  This column used to print DMA/core and call it the
        // fetch against the core; that reading is 1 + feed/core, which is why it
        // could never drop below one.  F2 (`make pta_feed`) measures the parts.
        const double ratio = cyc ? ((double)dma - (double)cyc) / (double)cyc : 0.0;
        if (ran != 1) {
            const char *why = ran == -1 ? "submit refused"
                            : ran == -2 ? "drain timed out"
                            : ran == -3 ? "o_error after the run"
                                        : "did not run";
            printf("[TB]   %-12s -- %s\n", rows[p].name, why);
            ++bad;
            continue;
        }
        printf("[TB]   %-12s %-9u %-9u %-8u %-7u %-7u %-7u %-6s %.2f\n",
               rows[p].name, cyc, dma, wmove, slot(p, 8), shots, progs,
               cok ? "ok" : "WRONG", ratio);
        if (!cok) { ++bad; }
    }

    // What the sweep exists to show: the ratio across the range, and what the
    // resident point costs against the scanned one it replaces.
    const uint32_t c_to1 = slot(0, 0), c_to10 = slot(1, 0);
    const uint32_t c_scan = slot(2, 0), c_fill = slot(3, 0), c_res = slot(4, 0);
    if (c_scan && c_res) {
        printf("[TB]   the range: TO-1ms %u to EO-scan %u, %.0fx\n",
               c_to1, c_scan, (double)c_to1 / (double)c_scan);
        printf("[TB]   EO-res %u against EO-scan %u: %.2fx, and the fill it "
               "amortises cost %u\n", c_res, c_scan,
               (double)c_scan / (double)c_res, c_fill);
        printf("[TB]   weight movement, EO-scan %u -> EO-res %u\n",
               slot(2, 3), slot(4, 3));
    }
    if (!c_to10) ++bad;

    // The shot's cost, derived rather than assumed: the total less the scan,
    // the restore and the write, over the number of runs.  This works whichever
    // tile answered -- PTM-C's skewed drain reports 2*2*(R+C) = 64 and takes no
    // dilation, PTM-B's shot reports PTA_TS plus its handshake -- and it is the
    // physical quantity, so nothing here needs a compile-time define.
    auto shot_of = [&](int p, uint32_t tw, bool resident) {
        const int nti = (int)nt, kti = (int)kt;
        const long scan = resident ? (long)nti * kti
                                   : (long)N * K
                                     + (long)nti * kti * (tw + (tw & 1u));
        const long other = scan + (long)M * (kti - 1) * N + (long)M * kti * N;
        const long runs  = (long)M * nti * kti;
        return (double)((long)slot(p, 0) - other) / (double)runs;
    };

    printf("[TB]   the shot, derived from each total (section 2.1's other terms removed):\n");
    printf("[TB]   %-12s %-9s %-9s %s\n", "point", "cycles", "a run", "A-row");
    {
        const uint32_t tws[NAMED] = { 100000, 1000, 0, 0, 0 };
        for (int p = 0; p < NAMED; p++)
            printf("[TB]   %-12s %-9u %-9.2f %u\n", rows[p].name,
                   slot(p, 0), shot_of(p, tws[p], p == 4), slot(p, 8));
    }

    // SoC-B's gate.  A shot dilated by PTA_TS costs one more cycle a run per
    // unit, so the total's slope is the number of runs.  On PTM-C the drain
    // ignores the register and the slope is zero, which is exactly why
    // section 6.2's Ts axis needed this build.
    printf("[TB]   PTA_TS swept at EO-scan's settings:\n");
    printf("[TB]   %-8s %-9s %-9s %s\n", "PTA_TS", "cycles", "a run", "step");
    {
        const long runs = (long)M * (int)nt * (int)kt;
        long prev = 0, first = 0, last = 0;
        int steps_ok = 1;
        for (int i = 0; i < NTS; i++) {
            const int p = NAMED + i;
            const long cyc = (long)slot(p, 0);
            if (!cyc) { ++bad; continue; }
            const long step = i ? cyc - prev : 0;
            const long want = i ? runs * (long)(TS_LIST[i] - TS_LIST[i - 1]) : 0;
            // Every step is on the line now.  PTA_TS = 1 used to sit below the
            // shot's six-cycle floor, so the step out of it was not checked as if
            // it were on the line; with the hop out of the broadside path the shot
            // is PTA_TS + 2 from PTA_TS = 1 upward and the whole sweep is straight.
            const bool on_line = (i >= 1);
            if (!i)
                printf("[TB]   %-8u %-9ld %-9.2f %s\n", TS_LIST[i], cyc,
                       shot_of(p, 0, false), "-- the line's first point");
            else
                printf("[TB]   %-8u %-9ld %-9.2f %+ld (want %+ld)\n",
                       TS_LIST[i], cyc, shot_of(p, 0, false), step, want);
            // Exactly, not within a cycle a run: the broadside shot has no hop
            // left in it, so a step that is off by anything is a real change.
            if (on_line && step != want) steps_ok = 0;
            if (!i) first = cyc;
            if (i == NTS - 1) last = cyc;
            prev = cyc;
        }
        // The span, which is what distinguishes a tile whose shot takes the
        // register from one whose drain ignores it.
        const long span = last - first;
        const long want_span = runs * (long)(TS_LIST[NTS - 1] - TS_LIST[0]);
        printf("[TB]   PTA_TS %u to %u: %+ld cycles, want %+ld\n",
               TS_LIST[0], TS_LIST[NTS - 1], span, want_span);
        if (labs(span) <= runs) {
            printf("[TB]   PTA_TS does not move the shot -- this build's drain"
                   " ignores it, so it is PTM-C and 6.2's Ts axis is not reachable"
                   " here (plan step SoC-B)\n");
        } else if (labs(span - want_span) > runs || !steps_ok) {
            printf("[TB]   FAIL: the shot moves with PTA_TS but not by the number of runs\n");
            ++bad;
        } else {
            printf("[TB]   the shot is PTA_TS plus a fixed handshake, and the total's slope is %ld a unit: SoC-B PASS\n", runs);
        }
    }

    const uint32_t diag = ddr_word(top, DIAG);
    const uint32_t res  = ddr_word(top, RESULT);
    printf("[TB]   DIAG=0x%02x RESULT=0x%08x\n", diag, res);
    if (res != PASS_MAGIC) {
        printf("[TB] FAIL: the firmware did not report every point good\n");
        return 1;
    }
    if (bad) {
        printf("[TB] FAIL: %d point(s) did not run or returned the wrong C\n", bad);
        return 1;
    }
    printf("[TB] PASS: section 6.2's four points measured on the SoC, EO-res "
           "included, in %d cycles\n", c);
    return 0;
}

// ---------------------------------------------------------------------------
// F2: the feed's options at the Pockels points, run on the SoC by sw/pta_feed.c
// (grxcp pta_program_plan.md, track F).  Nine batches: EO-scan and EO-res, each
// with the feed as built and with PTA_CTRL.STAGE_A, each of those at Q = 1 and
// Q = 4, plus the resident fill.  The firmware's header says why two batch
// sizes -- every per-GEMM counter resets on START, so a drained batch of four
// reports only its last GEMM, and 4*wall(Q=1) - wall(Q=4) is what queueing buys.
// ---------------------------------------------------------------------------
static int run_feed(Vc930_soc4_verilator *top) {
    const int M = 8, N = 12, K = 16;     // pta_sweep.c's shape, so the numbers compare
    const uint32_t A = 0x1000, B = 0x2000, C = 0x3000;
    const uint32_t DIMS = 0x9400, DONE = 0x9410, RESULT = 0x9420;
    const uint32_t DIAG = 0x9480, PHASE = 0x9490, TABLE = 0x9500;
    const uint32_t PASS_MAGIC = 0x0BADBEEF;
    // 1 warm-up + (1+4+1+4) + 1 fill + (1+4+1+4) + 1 odd-tail GEMMs
    const int NPTS = 11, STRIDE = 16, NBLK = 23;
    const int ODD_M = 3, ODD_N = 5, ODD_K = 16;   // the only odd M*N here

    enum { P_WARM, P_SCAN_Q1, P_SCAN_Q4, P_SCAN_S1, P_SCAN_S4, P_FILL,
           P_RES_Q1, P_RES_Q4, P_RES_S1, P_RES_S4, P_ODD };
    enum { FD_WALL, FD_CYCLES, FD_DMA_CT, FD_DMA_LAST, FD_STALL, FD_AROW,
           FD_SHOTS, FD_WLOADS, FD_COK, FD_RAN, FD_Q };

    printf("[TB] 4-core SoC -- F2: the feed's options at the Pockels points, "
           "driven by firmware\n");
    printf("[TB] shape M=%d N=%d K=%d: this SoC's NPU, not 6.2's. A is M*K=%d "
           "bytes (%d beats), of which row 0 is %d -- so STAGE_A moves %d beats "
           "out of the compute shadow\n", M, N, K, M * K, (M * K + 7) / 8,
           (K + 7) / 8, (M * K + 7) / 8 - (K + 7) / 8);

    top->i_rst_n = 0;
    top->i_tb_wr_en = 0;
    top->i_clk = 0; top->eval();

    const char *fw = getenv("PTA_FW");
    preload_words_at(top, fw ? fw : "sw/pta_feed_prog.hex", 0x0000, 8192);

    for (int i = 0; i < M * K; i++) preload_byte(top, A + i, 1);
    for (int i = 0; i < K * N; i++) preload_byte(top, B + i, 1);
    // A C block per GEMM, never reused -- see the firmware's c_base_of comment.
    for (int b = 0; b < NBLK; b++)
        for (int i = 0; i < M * N; i++)
            preload_word(top, C + 0x200 * b + i * 4, 0);
    preload_word(top, DIMS + 0, (uint32_t)M);
    preload_word(top, DIMS + 4, (uint32_t)N);
    preload_word(top, DIMS + 8, (uint32_t)K);
    preload_word(top, DIMS + 12, 0);
    preload_word(top, DONE, 0);
    preload_word(top, RESULT, 0);
    preload_word(top, DIAG, 0);
    preload_word(top, PHASE, 0);
    for (int i = 0; i < STRIDE * (NPTS + 1); i++)
        preload_word(top, TABLE + i * 4, 0);

    printf("[TB] image preloaded, all operands 1 so every C element is K=%d. "
           "Booting CPU0.\n", K);
    reset_release(top);

    // No thermo-optic point here, so this is far shorter than the sweep: 21
    // GEMMs of a few hundred cycles each, plus the CPU's submits.
    int c = -1;
    for (int t = 0; t < 4000000; t++) {
        clock_n(top, 1);
        if ((t % 500000) == 0 || t == 4000000 - 1)
            printf("[TB]   t=%-9d pc=0x%08llx npu=%d/%d dma=%d phase=0x%02x\n",
                   t, (unsigned long long)top->o_hart0_pc,
                   (int)top->o_npu0_busy, (int)top->o_npu0_done,
                   (int)top->o_dma0_phase, ddr_word(top, PHASE));
        if (ddr_word(top, DONE) == 0xDEADBEEF) { c = t; break; }
    }
    if (c >= 0) printf("[TB] feed: done after %d cycles\n", c);
    else {
        printf("[TB] feed: TIMEOUT after 4000000 cycles, PHASE=0x%02x\n",
               ddr_word(top, PHASE));
        return 1;
    }

    struct Row { const char *name; const char *what; };
    const Row rows[NPTS] = {
        { "warm-up",   "discarded: cold I-cache"       },
        { "scan Q=1",  "EO-scan, feed as built"        },
        { "scan Q=4",  "EO-scan, feed as built, queued" },
        { "scan S Q=1","EO-scan, STAGE_A"              },
        { "scan S Q=4","EO-scan, STAGE_A, queued"      },
        { "res fill",  "the resident fill"             },
        { "res Q=1",   "EO-res, feed as built"         },
        { "res Q=4",   "EO-res, feed as built, queued" },
        { "res S Q=1", "EO-res, STAGE_A"               },
        { "res S Q=4", "EO-res, STAGE_A, queued"       },
        { "odd tail",  "M*N odd, the half-full beat"   },
    };
    auto slot = [&](int p, int i) {
        return ddr_word(top, TABLE + 4u * STRIDE * (uint32_t)p + 4u * (uint32_t)i);
    };

    const uint32_t nt = ddr_word(top, TABLE + 4u * STRIDE * NPTS + 0);
    const uint32_t kt = ddr_word(top, TABLE + 4u * STRIDE * NPTS + 4);
    const uint32_t blks = ddr_word(top, TABLE + 4u * STRIDE * NPTS + 8);
    printf("[TB]   Nt=%u Kt=%u, so %u shots and (scanned) %u weight programs a "
           "GEMM; %u C blocks used of %d preloaded\n",
           nt, kt, (uint32_t)M * nt * kt, nt * kt, blks, NBLK);

    int bad = 0;
    printf("[TB]   %-11s %-3s %-9s %-8s %-8s %-8s %-7s %-7s %-6s %-6s %-5s %s\n",
           "batch", "Q", "wall", "core", "DMA", "DMAlast", "A-row", "wmove",
           "shots", "banks", "C", "wall/GEMM");
    for (int p = 0; p < NPTS; p++) {
        const int ran = (int)slot(p, FD_RAN);
        if (ran != 1) {
            const char *why = ran == -1 ? "submit refused"
                            : ran == -2 ? "drain timed out"
                            : ran == -3 ? "o_error after the batch"
                            : ran == -4 ? "queue never had room"
                            : ran == -5 ? "a C block was wrong"
                                        : "did not run";
            printf("[TB]   %-11s -- %s\n", rows[p].name, why);
            ++bad;
            continue;
        }
        const uint32_t q = slot(p, FD_Q);
        printf("[TB]   %-11s %-3u %-9u %-8u %-8u %-8u %-7u %-7u %-6u %-6u %-5s %.1f\n",
               rows[p].name, q, slot(p, FD_WALL), slot(p, FD_CYCLES),
               slot(p, FD_DMA_CT), slot(p, FD_DMA_LAST), slot(p, FD_AROW),
               slot(p, FD_STALL), slot(p, FD_SHOTS), slot(p, FD_WLOADS),
               slot(p, FD_COK) ? "ok" : "WRONG",
               q ? (double)slot(p, FD_WALL) / (double)q : 0.0);
        if (!slot(p, FD_COK)) ++bad;
    }
    printf("[TB]   core, DMA, DMAlast, A-row and wmove are the batch's LAST "
           "GEMM: they reset on START. wall, shots and banks are the whole "
           "batch.\n");
    printf("[TB]   \"banks\" is PTA_WLOAD_CT, which counts LEAVING S_WLOAD "
           "(wload_done), one per (N tile, K tile) -- a bank selection, not an "
           "array programming. Under WSKIP the state is still entered and left, "
           "so the count stands and the CYCLES (wmove) are what residency "
           "saves.\n");

    // ---- What F2 is choosing between -------------------------------------
    // DMA_CT counts every cycle with phase != P_IDLE, and P_LAUNCH -- the core's
    // whole compute -- is one of those phases.  So DMA_CT is not the fetch: it
    // is the GEMM, from the first AR to o_done, and the fetch is DMA_CT - core.
    // (pta_sweep.c's harness prints the raw DMA/core ratio and calls it "the
    // fetch against the core"; that reading is 1 + feed/core, which is why it
    // never drops below one.)
    printf("[TB]   the feed against the core, per GEMM (Q=1). DMA_CT counts "
           "P_LAUNCH too, so it is the whole GEMM and feed = DMA_CT - core:\n");
    printf("[TB]   %-16s %-8s %-8s %-8s %-9s %s\n",
           "point", "core", "GEMM", "feed", "feed/GEMM", "wall");
    const int q1[4] = { P_SCAN_Q1, P_SCAN_S1, P_RES_Q1, P_RES_S1 };
    for (int i = 0; i < 4; i++) {
        const int p = q1[i];
        const uint32_t cyc = slot(p, FD_CYCLES), dma = slot(p, FD_DMA_CT);
        const long feed = (long)dma - (long)cyc;
        printf("[TB]   %-16s %-8u %-8u %-8ld %-9.1f%% %u\n", rows[p].what, cyc,
               dma, feed, dma ? 100.0 * (double)feed / (double)dma : 0.0,
               slot(p, FD_WALL));
    }
    // Where the feed goes, from the DMA's own structure.  P_READ_A and P_READ_B
    // are 2 cycles a beat (RS_R latches, RS_UNPACK writes the whole beat through
    // the wide port); the C write burst is 1 (WS_STREAM places a beat a cycle
    // from c_mem's two read ports), plus the AW/B handshakes and one cycle of
    // pipeline fill.  It was 5 before F2 rebuilt it.
    {
        const int a_beats = (K + 7) / 8;            // row 0, as built
        const int b_beats = (K * N + 7) / 8;
        const int c_beats = (M * N + 1) / 2;
        const double rest = 2.0 * a_beats + 2 + 2.0 * b_beats + 2 + 3 + 1;
        printf("[TB]   the feed's parts at this shape, from the DMA's own "
               "structure: A row 0 %d beats x2+2 = %d, B %d x2+2 = %d, "
               "C %d beats x1+4 = %d (was x5+3 = %d), hand-off 3, done 1 -- "
               "writeback is %.0f%% of the feed, was %.0f%%\n",
               a_beats, 2 * a_beats + 2, b_beats, 2 * b_beats + 2,
               c_beats, c_beats + 4, 5 * c_beats + 3,
               100.0 * (c_beats + 4.0) / (rest + c_beats + 4.0),
               100.0 * (5.0 * c_beats + 3.0) / (rest + 5.0 * c_beats + 3.0));
    }

    // What is left once the feed is cut: the host's own cost.  The wall clock is
    // the CPU's, so wall - GEMM is what the submit writes and the drain polling
    // spend outside the engine entirely.  Printed because F3 has to say what
    // binds this SoC, and after F2 it is not the fabric.
    printf("[TB]   the host's share, per GEMM (Q=1): wall - GEMM, which is the "
           "submit MMIO writes and the drain poll:\n");
    for (int i = 0; i < 4; i++) {
        const int p = q1[i];
        const long over = (long)slot(p, FD_WALL) - (long)slot(p, FD_DMA_CT);
        printf("[TB]   %-16s wall %-7u GEMM %-7u host %-7ld (%.0f%% of the wall, "
               "%.1fx the GEMM)\n", rows[p].what, slot(p, FD_WALL),
               slot(p, FD_DMA_CT), over,
               slot(p, FD_WALL) ? 100.0 * (double)over / (double)slot(p, FD_WALL) : 0.0,
               slot(p, FD_DMA_CT) ? (double)over / (double)slot(p, FD_DMA_CT) : 0.0);
    }

    // What queueing buys, measured: four separate GEMMs against four queued.
    printf("[TB]   what the queue buys (4*wall(Q=1) - wall(Q=4)):\n");
    struct Pair { const char *name; int one, four; };
    const Pair pairs[4] = {
        { "EO-scan, as built", P_SCAN_Q1, P_SCAN_Q4 },
        { "EO-scan, STAGE_A ", P_SCAN_S1, P_SCAN_S4 },
        { "EO-res,  as built", P_RES_Q1,  P_RES_Q4  },
        { "EO-res,  STAGE_A ", P_RES_S1,  P_RES_S4  },
    };
    long gain[4];
    for (int i = 0; i < 4; i++) {
        const long serial = 4L * (long)slot(pairs[i].one, FD_WALL);
        const long queued = (long)slot(pairs[i].four, FD_WALL);
        gain[i] = serial - queued;
        printf("[TB]   %-18s serial %-8ld queued %-8ld %+ld (%+.1f%%)\n",
               pairs[i].name, serial, queued, gain[i],
               serial ? 100.0 * (double)gain[i] / (double)serial : 0.0);
    }
    printf("[TB]   PF2 is the difference between the two rows of each level: "
           "STAGE_A turns it off, so its rows keep only the submit-and-poll "
           "saving. F0 measured PF2 as a net loss at its own shape.\n");

    // The choice, by the gate's own measure: total cycles for four GEMMs.
    {
        int best_scan = (slot(P_SCAN_Q4, FD_WALL) <= slot(P_SCAN_S4, FD_WALL))
                        ? P_SCAN_Q4 : P_SCAN_S4;
        int best_res  = (slot(P_RES_Q4, FD_WALL) <= slot(P_RES_S4, FD_WALL))
                        ? P_RES_Q4 : P_RES_S4;
        printf("[TB]   chosen by measured total cycles, four GEMMs: EO-scan %s "
               "(%u against %u), EO-res %s (%u against %u)\n",
               rows[best_scan].name, slot(best_scan, FD_WALL),
               slot(best_scan == P_SCAN_Q4 ? P_SCAN_S4 : P_SCAN_Q4, FD_WALL),
               rows[best_res].name, slot(best_res, FD_WALL),
               slot(best_res == P_RES_Q4 ? P_RES_S4 : P_RES_Q4, FD_WALL));
    }

    // ---- Gates ------------------------------------------------------------
    // Only what must hold. Which option wins, and whether PF2 pays, are the
    // measurement -- F0 already found PF2 negative at its shape, so gating its
    // sign would be gating the answer.
    for (int p = 0; p < NPTS; p++) {
        if ((int)slot(p, FD_RAN) != 1) continue;
        // 1. The premise, checked rather than assumed: PF1 never makes the core
        //    wait at this shape, so staging cannot help by removing a wait.
        if (slot(p, FD_AROW) != 0) {
            printf("[TB]   FAIL: %s waited %u cycles for an A row -- PF1 binds "
                   "here after all, and F2's reasoning below assumes it does not\n",
                   rows[p].name, slot(p, FD_AROW));
            ++bad;
        }
        // 2. A shot per (output row, N tile, K tile), every batch, every mode.
        //    The odd-tail point is a different shape, so it gets its own tiles.
        const uint32_t pm = (p == P_ODD) ? (uint32_t)ODD_M : (uint32_t)M;
        const uint32_t pnt = (p == P_ODD) ? (uint32_t)((ODD_N + 7) / 8) : nt;
        const uint32_t pkt = (p == P_ODD) ? (uint32_t)((ODD_K + 7) / 8) : kt;
        const uint32_t want_shots = pm * pnt * pkt * slot(p, FD_Q);
        if (slot(p, FD_SHOTS) != want_shots) {
            printf("[TB]   FAIL: %s fired %u shots, want %u\n",
                   rows[p].name, slot(p, FD_SHOTS), want_shots);
            ++bad;
        }
    }
    // 3. Residency saves weight-movement CYCLES.  Not the bank count: see the
    //    note above the table -- PTA_WLOAD_CT counts leaving S_WLOAD, which
    //    WSKIP still does.  Without this check a resident point that quietly
    //    rescanned the array would still look fast enough to win.
    if ((int)slot(P_RES_Q1, FD_RAN) == 1 && (int)slot(P_SCAN_Q1, FD_RAN) == 1) {
        const uint32_t res_mv = slot(P_RES_Q1, FD_STALL);
        const uint32_t scan_mv = slot(P_SCAN_Q1, FD_STALL);
        if (res_mv >= scan_mv) {
            printf("[TB]   FAIL: WSKIP did not cut weight movement -- EO-res "
                   "spent %u cycles against EO-scan's %u\n", res_mv, scan_mv);
            ++bad;
        } else {
            printf("[TB]   WSKIP cuts weight movement %u -> %u cycles a GEMM, "
                   "which is the %u-cycle gap between the two cores\n",
                   scan_mv, res_mv,
                   slot(P_SCAN_Q1, FD_CYCLES) - slot(P_RES_Q1, FD_CYCLES));
        }
    }
    // 4. The writeback's tail beat.  M*N odd means the last beat carries one
    //    word under m_axi_wstrb = 0x0F; every other shape on this SoC is even,
    //    so without this point the restructured burst (F2) never writes one.
    if ((int)slot(P_ODD, FD_RAN) == 1 && slot(P_ODD, FD_COK))
        printf("[TB]   the odd tail: M=%d N=%d, %d words = %d beats with the "
               "last half full, C exact\n", ODD_M, ODD_N, ODD_M * ODD_N,
               (ODD_M * ODD_N + 1) / 2);
    // 5. STAGE_A is not inert.  Reading all M rows before launch has to cost
    //    more DMA than reading row 0, or the bit is not reaching the DMA -- the
    //    failure SoC-B hit with PTA_TS, reported rather than passed quietly.
    {
        const int sa[2][2] = { { P_SCAN_Q1, P_SCAN_S1 }, { P_RES_Q1, P_RES_S1 } };
        for (int i = 0; i < 2; i++) {
            if ((int)slot(sa[i][0], FD_RAN) != 1 ||
                (int)slot(sa[i][1], FD_RAN) != 1) continue;
            const uint32_t as_built = slot(sa[i][0], FD_DMA_LAST);
            const uint32_t staged   = slot(sa[i][1], FD_DMA_LAST);
            if (staged <= as_built) {
                printf("[TB]   FAIL: STAGE_A did not lengthen the DMA at %s "
                       "(%u against %u) -- PTA_CTRL bit 10 is not reaching the "
                       "DMA, so the staged rows are not being read\n",
                       rows[sa[i][1]].name, staged, as_built);
                ++bad;
            } else {
                printf("[TB]   STAGE_A costs %+d DMA cycles at %s, for %d more "
                       "beats of A read before launch\n",
                       (int)staged - (int)as_built, rows[sa[i][1]].name,
                       (M * K + 7) / 8 - (K + 7) / 8);
            }
        }
    }

    const uint32_t diag = ddr_word(top, DIAG);
    const uint32_t res  = ddr_word(top, RESULT);
    printf("[TB]   DIAG=0x%03x RESULT=0x%08x\n", diag, res);
    if (res != PASS_MAGIC) {
        printf("[TB] FAIL: the firmware did not report every batch good\n");
        return 1;
    }
    if (bad) {
        printf("[TB] FAIL: %d check(s) failed\n", bad);
        return 1;
    }
    printf("[TB] PASS: F2's feed options measured at both Pockels points, "
           "A-row wait included, in %d cycles\n", c);
    return 0;
}

static int run_pta(Vc930_soc4_verilator *top) {
    const int M = 8, N = 8, K = 16;          // 1 N tile, 2 K tiles
    const uint32_t A = 0x1000, B = 0x2000, C = 0x3000;
    const uint32_t DIMS = 0x9400, DONE = 0x9410, RESULT = 0x9420;
    const uint32_t REC = 0x9430, DIAG = 0x9480, PHASE = 0x9490;
    const uint32_t PASS_MAGIC = 0x0BADBEEF;

    printf("[TB] 4-core SoC (L2 ACTIVE) -- PTA mode: the register block, "
           "driven by firmware\n");
#ifdef PTM_C_BUILD
    printf("[TB] build: PTM-C, the modelled tile\n");
#else
    printf("[TB] build: reported by the firmware (see DIAG bit 8)\n");
#endif

    top->i_rst_n = 0;
    top->i_tb_wr_en = 0;
    top->i_clk = 0; top->eval();

    const char *fw = getenv("PTA_FW");
    preload_words_at(top, fw ? fw : "sw/pta_prog.hex", 0x0000, 8192);

    for (int i = 0; i < M * K; i++) preload_byte(top, A + i, 1);
    for (int i = 0; i < K * N; i++) preload_byte(top, B + i, 1);
    for (int i = 0; i < M * N; i++) preload_word(top, C + i * 4, 0);
    preload_word(top, DIMS + 0, (uint32_t)M);
    preload_word(top, DIMS + 4, (uint32_t)N);
    preload_word(top, DIMS + 8, (uint32_t)K);
    preload_word(top, DIMS + 12, 0);
    preload_word(top, DONE, 0);
    preload_word(top, RESULT, 0);
    preload_word(top, DIAG, 0);
    preload_word(top, PHASE, 0);
    // Every slot the report reads: a build that skips a test leaves its slots
    // alone, and an uninitialised DDR word would be read as its answer.
    for (int i = 0; i < 20; i++) preload_word(top, REC + i * 4, 0);

    printf("[TB] image preloaded, M=%d N=%d K=%d all ones. Booting CPU0.\n",
           M, N, K);
    reset_release(top);

    // Sample the machine as it goes: a stall that says only "it hung" costs
    // another run to locate, and the signals are already brought out.
    int c = -1;
    for (int t = 0; t < 8000000; t++) {
        clock_n(top, 1);
        if ((t % 250000) == 0 || t == 8000000 - 1)
            printf("[TB]   t=%-8d pc=0x%08llx dc=%d/%d l2=%d/%d npu=%d/%d "
                   "dma=%d disp=%d fifo=%d phase=%u\n",
                   t, (unsigned long long)top->o_hart0_pc,
                   (int)top->o_dc0_state, (int)top->o_dc0_stall,
                   (int)top->o_l2_rd_state, (int)top->o_l2_wr_state,
                   (int)top->o_npu0_busy, (int)top->o_npu0_done,
                   (int)top->o_dma0_phase, (int)top->o_csr0_disp,
                   (int)top->o_csr0_fifo, ddr_word(top, PHASE));
        if (ddr_word(top, DONE) == 0xDEADBEEF) { c = t; break; }
    }
    if (c >= 0) printf("[TB] pta: done after %d cycles\n", c);
    else        printf("[TB] pta: TIMEOUT after 8000000 cycles\n");
    uint32_t diag = ddr_word(top, DIAG);
    uint32_t res  = ddr_word(top, RESULT);
    if (c < 0) {
        printf("[TB]   npu_busy=%d npu_done=%d dma_phase=%d csr_disp=%d "
               "csr_fifo=%d done_latch=%d pc0=0x%08llx\n",
               (int)top->o_npu0_busy, (int)top->o_npu0_done,
               (int)top->o_dma0_phase, (int)top->o_csr0_disp,
               (int)top->o_csr0_fifo, (int)top->o_csr0_done_latch,
               (unsigned long long)top->o_hart0_pc);
        printf("[TB] FAIL: timeout, PHASE=%u DIAG=0x%03x\n",
               ddr_word(top, PHASE), diag);
        return 1;
    }
    printf("[TB] firmware finished in %d cycles: DIAG=0x%03x RESULT=0x%08x\n",
           c, diag, res);
    printf("[TB]   shots +%u (want %u), programmings +%u (want %u), C exact %u\n",
           ddr_word(top, REC + 0), ddr_word(top, REC + 8),
           ddr_word(top, REC + 4), ddr_word(top, REC + 12),
           ddr_word(top, REC + 16));
    printf("[TB]   impaired C all zero %u | guard status 0x%08x occupancy %u\n",
           ddr_word(top, REC + 20), ddr_word(top, REC + 24),
           ddr_word(top, REC + 28));
    printf("[TB]   cal_ct +%u status 0x%08x found %u left %u cal_cyc %u\n",
           ddr_word(top, REC + 32), ddr_word(top, REC + 36),
           ddr_word(top, REC + 40), ddr_word(top, REC + 44),
           ddr_word(top, REC + 48));
    // The probe amplitude is a bit position relative to the tile's operand
    // width, which no register reports, so the firmware finds one the tile
    // accepts and this says which -- 14 on this SoC's 16-bit tile, 6 on
    // tb_c930_npu's 8-bit one.  0xBAD means a calibration never started.
    printf("[TB]   probe amplitude 1 << %u%s\n", ddr_word(top, REC + 64),
           ddr_word(top, REC + 68) == 0xBAD ? " (and none ever started)" : "");
    printf("[TB]   refusal %u, then ran %u\n",
           ddr_word(top, REC + 52), ddr_word(top, REC + 56));

    static const struct { uint32_t bit; const char *what; } checks[7] = {
        {0x001, "T1 the decode reads back"},
        {0x002, "T2 the counters match the shape"},
        {0x004, "T3 the tile is listening"},
        {0x008, "T4 a calibration ran"},
        {0x010, "T5 a START during it queued"},
        {0x020, "T6 MODEL_RST cleared the correction"},
        {0x040, "T7 MZM_NL refused, then cleared"},
    };
    int fails = 0;
    for (int i = 0; i < 7; i++) {
        bool ok = (diag & checks[i].bit) != 0;
        printf("[TB]   %s %s\n", ok ? "[PASS]" : "[FAIL]", checks[i].what);
        if (!ok) fails++;
    }
    if (res != PASS_MAGIC) { printf("[TB]   [FAIL] RESULT is not PASS\n"); fails++; }
    // The firmware cannot know which tile it was given; this harness can.
    bool digital = (diag & 0x100) != 0;
#ifdef PTM_C_BUILD
    if (digital) { printf("[TB]   [FAIL] a PTM-C build refused its impairments\n"); fails++; }
    else printf("[TB]   [PASS] the build has a modelled tile\n");
#else
    printf("[TB]   the firmware reports %s\n",
           digital ? "a digital array, which refused every impairment"
                   : "a modelled tile");
#endif

    if (fails) { printf("[TB] FAIL: %d checks\n", fails); return 1; }
    printf("[TB] PASS: the PTA register block, through MMIO, in %d cycles\n", c);
    return 0;
}

// ---------------------------------------------------------------------------
// The M unit's result hold (sw/mul_store_test.S)
//
// Nine instructions that deadlocked the CPU: a multiply finishing into a
// pipeline that a store in MEM is stalling.  This checks the arithmetic as well
// as the liveness, because a lost-and-recomputed M result is invisible in a
// hang test, and back-to-back M instructions are where a hold keyed on the
// enable falling would hand the second one the first one's result.
// ---------------------------------------------------------------------------
static int run_mulstore(Vc930_soc4_verilator *top) {
    const uint32_t DONE = 0x9410, RESULT = 0x9420, REC = 0x9430, PHASE = 0x9490;
    const int BOUND = 100000;

    printf("[TB] 4-core SoC -- mulstore mode: the M unit's result hold\n");

    top->i_rst_n = 0;
    top->i_tb_wr_en = 0;
    top->i_clk = 0; top->eval();

    const char *fw = getenv("MULSTORE_FW");
    preload_words_at(top, fw ? fw : "sw/mul_store_prog.hex", 0x0000, 8192);
    preload_word(top, DONE, 0);
    preload_word(top, RESULT, 0);
    preload_word(top, PHASE, 0);
    for (int i = 0; i < 8; i++) preload_word(top, REC + i * 4, 0);
    reset_release(top);

    int c = -1;
    for (int t = 0; t < BOUND; t++) {
        clock_n(top, 1);
        if (ddr_word(top, DONE) == 0xDEADBEEF) { c = t; break; }
    }
    if (c < 0) {
        printf("[TB] FAIL: %d cycles and it never finished -- PHASE=%u "
               "pc0=0x%08llx dc=%d/%d\n", BOUND, ddr_word(top, PHASE),
               (unsigned long long)top->o_hart0_pc,
               (int)top->o_dc0_state, (int)top->o_dc0_stall);
        printf("[TB]   a store in MEM with an M instruction in EX: the result "
               "hold is not holding\n");
        return 1;
    }

    // The control build (NO_MUL=1) sums instead of multiplying, so it wants
    // different numbers from the same program.
    const bool nomul = (getenv("MULSTORE_NOMUL") != NULL);
    struct { const char *what; uint32_t got, want; } chk[] = {
        { "the first product",      ddr_word(top, RESULT)   , nomul ?  8u :  16u },
        { "back-to-back, first",    ddr_word(top, REC +  0), nomul ? 11u :  48u },
        { "back-to-back, second",   ddr_word(top, REC +  4), nomul ? 14u : 144u },
        { "the divide",             ddr_word(top, REC +  8), nomul ? 13u :   3u },
        { "the store that spun",    ddr_word(top, REC + 12), 0x1000u },
    };
    int bad = 0;
    for (unsigned i = 0; i < sizeof(chk) / sizeof(chk[0]); i++) {
        const bool ok = (chk[i].got == chk[i].want);
        if (!ok) bad++;
        printf("[TB]   [%s] %s: %u (want %u)\n", ok ? "PASS" : "FAIL",
               chk[i].what, chk[i].got, chk[i].want);
    }
    printf("[TB] finished in %d cycles, PHASE=%u\n", c, ddr_word(top, PHASE));
    if (bad) { printf("[TB] FAIL: %d of 5 wrong\n", bad); return 1; }
    printf("[TB] PASS: the M unit keeps its result across a stalled store\n");
    return 0;
}

// ---------------------------------------------------------------------------
// The command-queue driver, from firmware (sw/driver_test.c)
//
// Three back-to-back submits through npu_drv_submit -- the first starts the
// engine, the other two queue -- then one npu_drv_drain, then every C element
// checked on-core against the firmware's own software reference.  The same test
// make driver_test runs under iverilog, where it does not finish: 48,428
// seconds of simulator CPU here without printing, because TILE_WAIT_BOUND alone
// is 500,000 cycles per wait and the full SoC manages tens of cycles a second.
//
// The firmware does the checking, so this preloads the operands and the
// dimensions, waits for the magic and reads the verdict.  Occupancy must be
// zero at the end: the completion contract is the point of the test.
// ---------------------------------------------------------------------------
static int run_driver(Vc930_soc4_verilator *top) {
    struct Case { int M, N, K; };
    const Case cases[] = { {1, 1, 1}, {3, 4, 8}, {8, 12, 16} };
    const uint32_t A = 0x1000, B = 0x2000, C = 0x3000, C_REF = 0x4000;
    const uint32_t DIMS = 0x9400, DONE = 0x9410, RESULT = 0x9420;
    const uint32_t ST = 0x9430, DIAG = 0x9480, PHASE = 0x9490;
    const uint32_t PASS_MAGIC = 0x0BADBEEF;
    const int BOUND = 4000000;

    printf("[TB] 4-core SoC -- driver mode: submit/drain through the driver\n");

    int bad = 0;
    for (const Case &c : cases) {
        top->i_rst_n = 0;
        top->i_tb_wr_en = 0;
        top->i_clk = 0; top->eval();

        const char *fw = getenv("DRIVER_FW");
        preload_words_at(top, fw ? fw : "sw/driver_prog.hex", 0x0000, 8192);
        for (int i = 0; i < c.M * c.K; i++) preload_byte(top, A + i, (i % 7) - 3);
        for (int i = 0; i < c.K * c.N; i++) preload_byte(top, B + i, (i % 5) - 2);
        for (int i = 0; i < c.M * c.N; i++) {
            preload_word(top, C + i * 4, 0);
            preload_word(top, C_REF + i * 4, 0);
        }
        preload_word(top, DIMS + 0, (uint32_t)c.M);
        preload_word(top, DIMS + 4, (uint32_t)c.N);
        preload_word(top, DIMS + 8, (uint32_t)c.K);
        preload_word(top, DIMS + 12, 0);          // NPU_PREC_INT8
        preload_word(top, DONE, 0);
        preload_word(top, RESULT, 0);
        preload_word(top, DIAG, 0);
        preload_word(top, PHASE, 0);
        for (int i = 0; i < 6; i++) preload_word(top, ST + i * 4, 0);
        reset_release(top);

        int cyc = -1;
        for (int t = 0; t < BOUND; t++) {
            clock_n(top, 1);
            if (ddr_word(top, DONE) == 0xDEADBEEF) { cyc = t; break; }
        }
        const uint32_t res = ddr_word(top, RESULT);
        const uint32_t occ = ddr_word(top, ST + 16);
        const bool ok = (cyc >= 0) && (res == PASS_MAGIC) && (occ == 0);
        if (!ok) bad++;
        if (cyc < 0)
            printf("[TB]   [FAIL] M=%d N=%d K=%d never finished: PHASE=%u pc0=0x%08llx\n",
                   c.M, c.N, c.K, ddr_word(top, PHASE),
                   (unsigned long long)top->o_hart0_pc);
        else
            printf("[TB]   [%s] M=%-2d N=%-2d K=%-2d in %6d cycles: RESULT=0x%08x "
                   "occupancy=%u DIAG=%u\n", ok ? "PASS" : "FAIL",
                   c.M, c.N, c.K, cyc, res, occ, ddr_word(top, DIAG));
    }
    if (bad) {
        printf("[TB] FAIL: %d of 3 dims\n", bad);
        return 1;
    }
    printf("[TB] PASS: three back-to-back submits, drained, C verified on-core, "
           "at three dims\n");
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);  // unbuffered for live traces
    Verilated::commandArgs(argc, argv);
    Vc930_soc4_verilator *top = new Vc930_soc4_verilator;

    std::string mode = (argc > 1) ? argv[1] : "quad";
    int rc;
    if (mode == "suite")
        rc = run_suite(top);
    else if (mode == "pta")
        rc = run_pta(top);
    else if (mode == "sweep")
        rc = run_sweep(top);
    else if (mode == "feed")
        rc = run_feed(top);
    else if (mode == "l2coh")
        rc = run_l2coh(top);
    else if (mode == "mulstore")
        rc = run_mulstore(top);
    else if (mode == "driver")
        rc = run_driver(top);
    else
        rc = run_quad(top);

    top->final();
    delete top;
    return rc;
}
