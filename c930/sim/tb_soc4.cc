// tb_soc4.cc -- Verilator harness for the FULL 4-core SoC with the shared
// L2 cache ACTIVE.  Mirrors tb_quad_isolated.sv: preloads the quadcore DDR
// image + operands, boots all 4 harts, and waits for CPU0 to write the
// 0xFACEFEED magic to DDR[0x9400] (only reached after all 4 harts complete
// and pass their on-core C-matrix checks).
//
// This is the hardware-speed path for verifying L2 coherence in the full
// 4-core integration, which Icarus cannot simulate at usable speed.
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#include "Vc930_soc4_verilator.h"
#include "Vc930_soc4_verilator___024root.h"
#include "verilated.h"

// Accessor for a DDR byte via the testbench readback port.
static const int MEM_BYTES = 65536;

static inline uint8_t ddr_byte(Vc930_soc4_verilator *top, uint32_t addr) {
    top->i_tb_rd_addr = addr & (MEM_BYTES-1);
    top->eval();
    return top->o_tb_rd_data;
}

// Parse a 2-hex-digit-per-token byte hex file and write it via the TB
// preload port (clocked).  Mirrors the SV load_hex task.
static void preload_hex(Vc930_soc4_verilator *top, const char *fname) {
    FILE *f = fopen(fname, "r");
    if (!f) { fprintf(stderr, "[TB] cannot open %s\n", fname); exit(2); }
    uint32_t a = 0;
    unsigned b;
    while (a < MEM_BYTES && fscanf(f, "%2x", &b) == 1) {
        top->i_tb_wr_en   = 1;
        top->i_tb_wr_addr = a;
        top->i_tb_wr_data = (uint8_t)b;
        top->i_clk = 0; top->eval();
        top->i_clk = 1; top->eval();
        a++;
    }
    top->i_tb_wr_en = 0;
    fclose(f);
    printf("[TB] loaded %u bytes from %s\n", a, fname);
}

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

static void clock_n(Vc930_soc4_verilator *top, int n) {
    for (int i = 0; i < n; i++) {
        top->i_clk = 0; top->eval();
        top->i_clk = 1; top->eval();
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vc930_soc4_verilator *top = new Vc930_soc4_verilator;

    printf("[TB] 4-core SoC (L2 ACTIVE) Verilator model starting\n");

    // ---- Reset, then preload DDR (mirrors tb_quad_isolated) ----
    top->i_rst_n = 0;
    top->i_tb_wr_en = 0;
    top->i_clk = 0; top->eval();

    // Firmware
    preload_hex(top, "sw/quadcore_ddr_bytes.hex");

    // Operands (mirror TB)
    for (int i = 0; i < 16; i++) { preload_byte(top, 0x8000+i, 0x01); preload_byte(top, 0x8400+i, 0x01); }
    for (int i = 0; i < 9;  i++) { preload_byte(top, 0xA000+i, 0x02); preload_byte(top, 0xA400+i, 0x02); }
    for (int i = 0; i < 9;  i++) { preload_byte(top, 0xB000+i, 0x03); preload_byte(top, 0xB400+i, 0x03); }
    for (int i = 0; i < 16; i++) { preload_byte(top, 0xD000+i, 0x04); preload_byte(top, 0xD400+i, 0x04); }
    // Clear status + magic region
    for (int i = 0; i < 1280; i++) preload_byte(top, 0x9000+i, 0x00);

    printf("[TB] DDR preloaded. Releasing reset.\n");

    // ---- Boot ----
    clock_n(top, 10);
    top->i_rst_n = 1;
    top->i_clk = 0; top->eval();

    // ---- Wait for CPU0 DONE magic ----
    const int MAX = 2000000;
    int cyc = 0;
    bool pass = false;
    bool was_dma = false, was_l2 = false;
    for (; cyc < MAX; cyc++) {
        clock_n(top, 1);
        if (cyc % 25000 == 0)
            printf("[TB] cyc %d: l2_rd=%d dma_ph=%d pc0=0x%08llx\n", cyc,
                   (int)top->o_l2_rd_state, (int)top->o_dma0_phase,
                   (unsigned long long)top->o_hart0_pc);
        uint32_t got = (uint32_t)ddr_byte(top, 0x9400) |
                       ((uint32_t)ddr_byte(top, 0x9401) << 8) |
                       ((uint32_t)ddr_byte(top, 0x9402) << 16) |
                       ((uint32_t)ddr_byte(top, 0x9403) << 24);
        if (got == 0xFACEFEED) { pass = true; break; }
        if (cyc > 0 && cyc % 25000 == 0)
            printf("[TB] cycle %d: still running... (uart_txd=%d npu0_done=%d)\n",
                   cyc, (int)top->o_uart_txd, (int)top->o_npu0_done);
    }

    // Per-hart status dump (HART_ID @ +0, C-verify err mask @ +4, phase @ +8)
    for (int c = 0; c < 4; c++) {
        uint32_t h = 0x9000 + c*256;
        printf("[TB] hart %d: hartid=0x%08x errmask=0x%08x phase=0x%08x\n", c,
               (uint32_t)ddr_byte(top, h) | ((uint32_t)ddr_byte(top, h+1) << 8) |
               ((uint32_t)ddr_byte(top, h+2) << 16) | ((uint32_t)ddr_byte(top, h+3) << 24),
               (uint32_t)ddr_byte(top, h+4) | ((uint32_t)ddr_byte(top, h+5) << 8) |
               ((uint32_t)ddr_byte(top, h+6) << 16) | ((uint32_t)ddr_byte(top, h+7) << 24),
               (uint32_t)ddr_byte(top, h+8) | ((uint32_t)ddr_byte(top, h+9) << 8) |
               ((uint32_t)ddr_byte(top, h+10) << 16) | ((uint32_t)ddr_byte(top, h+11) << 24));
    }

    if (pass) {
        printf("[TB] PASS: 0xFACEFEED magic at DDR[0x9400] after %d cycles "
               "(all 4 harts + shared L2)\n", cyc);
    } else {
        printf("[TB] TIMEOUT after %d cycles. magic=0x%08x\n", cyc,
               (uint32_t)ddr_byte(top, 0x9400) |
               ((uint32_t)ddr_byte(top, 0x9401) << 8) |
               ((uint32_t)ddr_byte(top, 0x9402) << 16) |
               ((uint32_t)ddr_byte(top, 0x9403) << 24));
    }

    top->final();
    delete top;
    return pass ? 0 : 1;
}