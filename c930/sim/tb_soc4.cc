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
    else if (mode == "mulstore")
        rc = run_mulstore(top);
    else
        rc = run_quad(top);

    top->final();
    delete top;
    return rc;
}
