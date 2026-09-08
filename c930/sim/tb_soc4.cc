// tb_soc4.cc -- Verilator harness for the FULL 4-core SoC with the shared
// L2 cache ACTIVE (the path Icarus cannot simulate at usable speed).
//
// Modes (argv[1]):
//   (none) / "quad" : mirrors tb_quad_isolated.sv -- preloads the quadcore
//                     DDR image + operands, boots all 4 harts, waits for
//                     CPU0 to write the 0xFACEFEED magic to DDR[0x9400].
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

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);  // unbuffered for live traces
    Verilated::commandArgs(argc, argv);
    Vc930_soc4_verilator *top = new Vc930_soc4_verilator;

    std::string mode = (argc > 1) ? argv[1] : "quad";
    int rc;
    if (mode == "suite")
        rc = run_suite(top);
    else
        rc = run_quad(top);

    top->final();
    delete top;
    return rc;
}
