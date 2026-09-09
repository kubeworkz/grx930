/**
 * tb_uart_echo.cc -- UART echo testbench for the GRX930 single-core SoC
 * Verilator model (c930_soc_verilator.sv).
 *
 * Flow:
 *   1. Preload the echo firmware hex into DDR (addr 0) via the TB preload port.
 *   2. Release reset; the RV64IMAC core boots from PC=0 and runs the echo loop.
 *   3. Drive i_uart_rxd with real 115200-baud frames (start + 8N1).
 *   4. Sample o_uart_txd at mid-bit to capture the firmware's replies.
 *   5. Verify PING / ECHO / VERSION responses.
 *
 * Build (server):
 *   cd c930 && bash sim/build_grx930_verilator.sh   (after editing the TB var)
 * Run:
 *   ./build/verilator_soc/Vc930_soc_verilator firmware_uart_echo_test.hex
 */

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "Vc930_soc_verilator.h"
#include "verilated.h"

// ============================================================================
// Configuration (must match the c930_soc_top instantiation)
// ============================================================================
static const uint64_t MEM_SIZE   = 65536;        // DDR model (64 KB)
static const uint64_t BAUD       = 115200;
static const uint64_t CORE_CLK   = 100000000;    // 100 MHz, CLK_DIV=1
static const uint64_t BIT_CYCLES = CORE_CLK / BAUD;  // ~868 cycles per bit

// ============================================================================
// Simulation state
// ============================================================================
static Vc930_soc_verilator *top = nullptr;
static uint64_t cycle = 0;

static void tick() {
    top->i_clk = 0; top->eval();
    top->i_clk = 1; top->eval();
    cycle++;
}

// ============================================================================
// DDR preload (TB port)
// ============================================================================
static void preload_byte(uint32_t addr, uint8_t data) {
    top->i_tb_wr_en   = 1;
    top->i_tb_wr_addr = addr;
    top->i_tb_wr_data = data;
    tick();
    top->i_tb_wr_en = 0;
    tick();
}

// Load a one-32-bit-word-per-line hex image into DDR at base 0.
static bool load_firmware_hex(const char *fname) {
    FILE *f = fopen(fname, "r");
    if (!f) { fprintf(stderr, "[TB] cannot open %s\n", fname); return false; }

    char line[64];
    uint32_t addr = 0;
    size_t words = 0;
    while (fgets(line, sizeof(line), f)) {
        // strip whitespace / comments
        char *end = nullptr;
        unsigned long v = strtoul(line, &end, 16);
        if (end == line) continue;  // blank line
        preload_byte(addr + 0, (uint8_t)(v & 0xFF));
        preload_byte(addr + 1, (uint8_t)((v >> 8) & 0xFF));
        preload_byte(addr + 2, (uint8_t)((v >> 16) & 0xFF));
        preload_byte(addr + 3, (uint8_t)((v >> 24) & 0xFF));
        addr += 4;
        words++;
    }
    fclose(f);
    printf("[TB] preloaded %zu words (%u bytes) from %s\n", words, words * 4, fname);
    return true;
}

// ============================================================================
// UART TX (host -> chip): drive i_uart_rxd
// ============================================================================
static void uart_send_byte(uint8_t byte) {
    // start bit (0)
    top->i_uart_rxd = 0;
    for (uint64_t i = 0; i < BIT_CYCLES; i++) tick();
    // 8 data bits, LSB first
    for (int b = 0; b < 8; b++) {
        top->i_uart_rxd = (byte >> b) & 1;
        for (uint64_t i = 0; i < BIT_CYCLES; i++) tick();
    }
    // stop bit (1)
    top->i_uart_rxd = 1;
    for (uint64_t i = 0; i < BIT_CYCLES; i++) tick();
}

// ============================================================================
// UART RX (chip -> host): sample o_uart_txd
// ============================================================================
static bool wait_for_tx_byte(uint8_t *out, uint64_t timeout_cycles) {
    // Wait for the start-bit falling edge (idle high -> low)
    uint64_t waited = 0;
    bool prev = top->o_uart_txd;
    while (waited < timeout_cycles) {
        tick();
        bool cur = top->o_uart_txd;
        if (prev == 1 && cur == 0) {
            // found falling edge: start bit. Wait half a bit, then sample
            // 8 data bits at mid-bit.
            uint8_t byte = 0;
            // skip to middle of start bit
            for (uint64_t i = 0; i < BIT_CYCLES / 2; i++) tick();
            // sample each data bit at mid-bit
            for (int b = 0; b < 8; b++) {
                for (uint64_t i = 0; i < BIT_CYCLES; i++) tick();
                byte |= (top->o_uart_txd & 1) << b;
            }
            // skip stop bit
            for (uint64_t i = 0; i < BIT_CYCLES; i++) tick();
            *out = byte;
            return true;
        }
        prev = cur;
        waited++;
    }
    return false;
}

// ============================================================================
// Test helpers
// ============================================================================
static int failures = 0;

static void expect_response(const std::string &expected, const char *testname) {
    std::string got;
    for (size_t i = 0; i < expected.size(); i++) {
        uint8_t b;
        if (!wait_for_tx_byte(&b, BIT_CYCLES * 200)) {
            printf("  %-32s FAIL (timeout waiting for byte %zu)\n", testname, i);
            failures++;
            return;
        }
        got += (char)b;
    }
    bool ok = (got == expected);
    printf("  %-32s %s  (got \"%s\")\n", testname, ok ? "PASS" : "FAIL",
           ok ? expected.c_str() : got.c_str());
    if (!ok) failures++;
}

// ============================================================================
// Main
// ============================================================================
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    const char *hexfile = "firmware_uart_echo_test.hex";
    if (argc > 1) hexfile = argv[1];

    top = new Vc930_soc_verilator;

    // init
    top->i_clk = 0;
    top->i_rst_n = 0;
    top->i_tb_wr_en = 0;
    top->i_tb_wr_addr = 0;
    top->i_tb_wr_data = 0;
    top->i_tb_rd_addr = 0;
    top->i_uart_rxd = 1;   // UART idle high
    top->eval();

    // 1. Load firmware into DDR at 0x0
    if (!load_firmware_hex(hexfile)) return 1;

    // 2. Reset sequence
    printf("[TB] releasing reset\n");
    for (int i = 0; i < 10; i++) tick();
    top->i_rst_n = 1;

    // 2b. Sanity: verify preload landed and the core is fetching
    {
        // read back DDR[0..3] through the TB readback port
        auto rd = [&](uint32_t a) -> uint8_t {
            top->i_tb_rd_addr = a; top->eval(); return top->o_tb_rd_data;
        };
        printf("[TB] DDR[0..7] = %02x %02x %02x %02x %02x %02x %02x %02x (want 37 81 00 00 ef 00 e0 27)\n",
               rd(0), rd(1), rd(2), rd(3), rd(4), rd(5), rd(6), rd(7));
        // run a few hundred cycles and report PC movement
        uint64_t pc_start = top->o_hart0_pc;
        for (int i = 0; i < 5000; i++) tick();
        printf("[TB] hart0 PC @5K cycles = 0x%08lx (start 0x%08lx)\n",
               (unsigned long)top->o_hart0_pc, (unsigned long)pc_start);
        // trace the L2/DDR read path: print whenever the state changes
        // (capped) so we see the full sequence from boot to the stall.
        top->i_clk = 1; top->eval();
        printf("[TB] ---- L2/DDR read-path state changes ----\n");
        int last_rd = -1, last_rb = -1, last_rv = -1, last_rr = -1, last_dc_st = -1, printed = 0;
        int last_ws = -1, last_xws = -1; int last_m1aw = -1;
        for (int w = 0; w < 60000 && printed < 250; w++) {
            int rd = (int)top->o_l2_rd_state;
            int rb = top->o_ddr_r_busy;
            int rv = top->o_ddr_m_rvalid;
            int rr = top->o_ddr_m_rready;
            int dc_st = (int)top->o_dcache_ctrl_state;
            int ws  = (int)top->o_l2_wr_state;
            int xws = (int)top->o_xbar_w_state;
            if (rd != last_rd || rb != last_rb || rv != last_rv || rr != last_rr ||
                dc_st != last_dc_st || ws != last_ws || xws != last_xws ||
                top->o_xbar_m1_awvalid != last_m1aw) {
                printf("[%5d] L2 rd=%d beat=%d | DDR rbusy=%d rbeat=%d rvalid=%d rready=%d | "
                       "dcST=%d iwr=%d addr=%03lx hit=%d upd=%d wr_en=%d mwv=%d mrr=%d rdone=%d ast=%d | "
                       "xbar wst=%d wgr=%d m1aw=%d/%d m1w=%d/%d m1b=%d | s1aw=%d/%d s1w=%d/%d s1b=%d/%d | l2wr=%d pc=0x%08lx\n",
                       w,
                       rd, (int)top->o_l2_rd_beat,
                       rb, (int)top->o_ddr_r_beat,
                       rv, rr,
                       dc_st,
                       top->o_dc_i_write, (unsigned long)top->o_dc_addr_lo,
                       top->o_dc_tag_hit, top->o_dc_update_en,
                       top->o_dc_wr_en, top->o_dc_mem_write_valid,
                       top->o_dc_mem_read_req, top->o_dc_rd_done,
                       (int)top->o_dc_adapt_state,
                       xws, (int)top->o_xbar_w_grant,
                       top->o_xbar_m1_awvalid, top->o_xbar_m1_awready,
                       top->o_xbar_m1_wvalid, top->o_xbar_m1_bvalid,
                       top->o_xbar_s1_awvalid, top->o_xbar_s1_awready,
                       top->o_xbar_s1_wvalid, top->o_xbar_s1_wready,
                       top->o_xbar_s1_bvalid, top->o_xbar_s1_bready,
                       ws,
                       (unsigned long)top->o_hart0_pc);
                last_rd = rd; last_rb = rb; last_rv = rv; last_rr = rr;
                last_dc_st = dc_st; last_ws = ws; last_xws = xws;
                last_m1aw = top->o_xbar_m1_awvalid;
                printed++;
            }
            tick();
        }
        printf("[TB] ---- end trace (printed %d changes) ----\n", printed);
        for (int i = 0; i < 40000; i++) tick();
        printf("[TB] hart0 PC @100K cycles = 0x%08lx\n",
               (unsigned long)top->o_hart0_pc);
        // dump store-path probes (sampled at the stall point)
        printf("[TB] store path: adapter_state=%d wr_valid=%d wr_done=%d | "
               "xbar M1 AW valid=%d ready=%d | L2 S AW v=%d r=%d W v=%d r=%d B v=%d r=%d | "
               "DDR M AW v=%d r=%d W v=%d r=%d B v=%d r=%d\n",
               (int)top->o_dcache_adapter_state,
               top->o_adapter_wr_valid, top->o_adapter_wr_done,
               top->o_xbar_m1_awvalid, top->o_xbar_m1_awready,
               top->o_l2_s_awvalid, top->o_l2_s_awready,
               top->o_l2_s_wvalid, top->o_l2_s_wready,
               top->o_l2_s_bvalid, top->o_l2_s_bready,
               top->o_ddr_m_awvalid, top->o_ddr_m_awready,
               top->o_ddr_m_wvalid, top->o_ddr_m_wready,
               top->o_ddr_m_bvalid, top->o_ddr_m_bready);
        printf("[TB] read path: xbar M1 AR v=%d r=%d R v=%d r=%d | L2 S AR v=%d r=%d R v=%d r=%d | "
               "DDR M AR v=%d r=%d R v=%d r=%d | inv v=%d ack=%d | dcache STATE=%d wr_addr=0x%08lx\n",
               top->o_xbar_m1_arvalid, top->o_xbar_m1_arready,
               top->o_xbar_m1_rvalid, top->o_xbar_m1_rready,
               top->o_l2_s_arvalid, top->o_l2_s_arready,
               top->o_l2_s_rvalid, top->o_l2_s_rready,
               top->o_ddr_m_arvalid, top->o_ddr_m_arready,
               top->o_ddr_m_rvalid, top->o_ddr_m_rready,
               top->o_l2_inv_valid, top->o_l2_inv_ack,
               (int)top->o_dcache_ctrl_state,
               (unsigned long)top->o_dcache_wr_addr);
        printf("[TB] L2/DDR: rd_state=%d rd_beat=%d | DDR r_busy=%d r_beat=%d | "
               "wr_seq=%d wr_log_head=%d wr_log_full=%d\n",
               (int)top->o_l2_rd_state, (int)top->o_l2_rd_beat,
               top->o_ddr_r_busy, (int)top->o_ddr_r_beat,
               (int)top->o_l2_wr_seq, (int)top->o_l2_wr_log_head,
               top->o_l2_wr_log_full);
    }

    // Let firmware boot: it prints a fixed banner before entering the loop:
    //   "\r\n=== GRX930 UART Echo Test ===\r\nReady. Waiting for commands...\r\n"
    // Drain exactly that many bytes (63) so TX is back at idle before the
    // first command is sent.  Each banner byte has a generous timeout.
    const char *BANNER = "\r\n=== GRX930 UART Echo Test ===\r\nReady. Waiting for commands...\r\n";
    size_t banner_len = strlen(BANNER);
    printf("[TB] waiting for boot banner (%zu bytes)...\n", banner_len);
    uint8_t b;
    bool banner_ok = true;
    for (size_t i = 0; i < banner_len; i++) {
        if (!wait_for_tx_byte(&b, BIT_CYCLES * 200)) {
            banner_ok = false;
            break;
        }
        if (b != (uint8_t)BANNER[i]) {
            printf("[TB] banner byte %zu mismatch: got 0x%02X want 0x%02X\n",
                   i, b, (uint8_t)BANNER[i]);
            banner_ok = false;
            break;
        }
    }
    if (!banner_ok) {
        printf("[TB] WARNING: boot banner mismatch (UART bytes != expected)\n");
    } else {
        printf("[TB] boot banner verified\n");
    }

    // 3. Tests
    printf("\nRunning UART echo tests...\n");
    printf("==========================\n\n");

    printf("Test: PING...\n");
    uart_send_byte('P');
    expect_response("PONGA", "PING -> PONGA");

    printf("Test: ECHO 'Hello'...\n");
    uart_send_byte('E');
    uart_send_byte(5);          // length
    uart_send_byte('H'); uart_send_byte('e'); uart_send_byte('l');
    uart_send_byte('l'); uart_send_byte('o');
    expect_response("HelloA", "ECHO Hello -> HelloA");

    printf("Test: VERSION...\n");
    uart_send_byte('V');
    expect_response("GRX930_ECHO_V1A", "VERSION -> GRX930_ECHO_V1A");

    printf("Test: UNKNOWN CMD...\n");
    uart_send_byte('X');
    expect_response("ERR_UNKNOWN_CMDXE", "UNKNOWN -> ERR_UNKNOWN_CMDXE");

    // 4. Summary
    printf("\n==========================\n");
    printf("Total cycles: %lu\n", cycle);
    if (failures == 0) {
        printf("ALL UART TESTS PASSED\n");
    } else {
        printf("%d TEST(S) FAILED\n", failures);
    }

    top->final();
    delete top;
    return failures == 0 ? 0 : 1;
}