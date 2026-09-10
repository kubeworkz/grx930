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
static const uint64_t CORE_CLK   = 100000000;    // 100 MHz, CLK_DIV=1
// The UART's baud is set by firmware to divisor 53: baud = clk/((div+1)*16)
// = 100e6/864 = 115740 Hz, i.e. EXACTLY 864 cycles per bit.  The nominal
// 115200 (868 cycles) differs by 0.47%; over a 10-bit frame that drift puts
// the UART's mid-stop sample on the last data bit and the RX stop-bit check
// fails, silently dropping the byte.  Use the UART's ACTUAL bit period.
static const uint64_t UART_DIV   = 53;
static const uint64_t BIT_CYCLES = (UART_DIV + 1) * 16;  // 864 cycles per bit

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

// Load a firmware hex image into DDR at base 0.  Handles both formats
// produced by the firmware Makefile:
//   - objcopy -O verilog: an optional "@80000000" header line, then 16
//     whitespace-separated BYTE tokens per line ("17 01 04 00 ..."), and
//   - the older hand/one-word-per-line form: one 8-hex-digit WORD per line
//     ("00008137"), big-endian.
// A token of 8 hex digits is a word (stored big-endian); shorter tokens are
// raw bytes stored in order.
static bool load_firmware_hex(const char *fname) {
    FILE *f = fopen(fname, "r");
    if (!f) { fprintf(stderr, "[TB] cannot open %s\n", fname); return false; }

    char line[256];
    uint32_t addr = 0;
    size_t words = 0;
    size_t nbytes = 0;
    while (fgets(line, sizeof(line), f)) {
        char *tok = strtok(line, " \t\r\n");
        while (tok) {
            if (tok[0] != '@' && tok[0] != '/' && tok[0] != '#') {
                char *end = nullptr;
                unsigned long v = strtoul(tok, &end, 16);
                if (end != tok) {
                    if (strlen(tok) >= 8) {
                        // 8-digit word, little-endian in memory
                        preload_byte(addr + 0, (uint8_t)(v & 0xFF));
                        preload_byte(addr + 1, (uint8_t)((v >> 8) & 0xFF));
                        preload_byte(addr + 2, (uint8_t)((v >> 16) & 0xFF));
                        preload_byte(addr + 3, (uint8_t)((v >> 24) & 0xFF));
                        addr += 4;
                        words++;
                        nbytes += 4;
                    } else {
                        // single byte
                        preload_byte(addr, (uint8_t)v);
                        addr++;
                        nbytes++;
                        if ((nbytes & 3) == 0) words++;
                    }
                }
            }
            tok = strtok(nullptr, " \t\r\n");
        }
    }
    fclose(f);
    printf("[TB] preloaded %zu words (%zu bytes) from %s\n", words, nbytes, fname);
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

// Send a command byte and collect the reply, listening on TX from the stop
// bit onward.  The UART commits the RX byte to the FIFO at its stop check
// (~8,260 cycles into the 8,640-cycle frame) and the firmware answers within
// ~50-150 cycles -- i.e. the reply's first start edge lands BEFORE the
// command frame's stop bit completes.  A plain send-then-listen would join
// mid-reply-frame and decode garbage (observed for ECHO/VERSION/UNKNOWN while
// PING passed only because its watch ended early).
static std::string send_and_collect(uint8_t cmd, int nbytes, uint64_t timeout) {
    top->i_uart_rxd = 0;
    for (uint64_t i = 0; i < BIT_CYCLES; i++) tick();
    for (int b = 0; b < 8; b++) {
        top->i_uart_rxd = (cmd >> b) & 1;
        for (uint64_t i = 0; i < BIT_CYCLES; i++) tick();
    }
    top->i_uart_rxd = 1;  // stop bit (stays high while we listen on TX)
    std::string got;
    for (int i = 0; i < nbytes; i++) {
        uint8_t b;
        if (!wait_for_tx_byte(&b, timeout)) break;
        got += (char)b;
    }
    return got;
}

// ============================================================================
// Test helpers
// ============================================================================
static int failures = 0;

// Read a 64-bit chunk (word index w) from a Verilator WData array (32-bit words).
static unsigned long long rd64(const uint32_t *p, int w) {
    return ((unsigned long long)p[w * 2 + 1] << 32) | p[w * 2];
}

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
        // run a few cycles to settle, then report PC
        uint64_t pc_start = top->o_hart0_pc;
        for (int i = 0; i < 20; i++) tick();
        printf("[TB] hart0 PC @20 cycles = 0x%08lx (start 0x%08lx)\n",
               (unsigned long)top->o_hart0_pc, (unsigned long)pc_start);
        // trace the read path from cycle 0: print whenever the state changes
        // (capped) so we see the GOT loads + fills from boot.
        top->i_clk = 1; top->eval();
        printf("[TB] ---- read-path state changes (from cycle 0) ----\n");
        int last_rd = -1, last_rb = -1, last_rv = -1, last_rr = -1, last_dc_st = -1, printed = 0;
        int last_ws = -1, last_xws = -1; int last_m1aw = -1;
        int last_upd = -1, last_rden = -1;
        // Trace the boot window only (BSS clear + UART init happen by ~cycle
        // 300 and the boot banner starts transmitting at ~cycle 400, so the
        // banner drain below must begin before then -- a 120K-cycle trace put
        // the drain mid-frame and garbled every sampled byte).
        for (int w = 0; w < 240 && printed < 400; w++) {
            int rd = (int)top->o_l2_rd_state;
            int rb = top->o_ddr_r_busy;
            int rv = top->o_ddr_m_rvalid;
            int rr = top->o_ddr_m_rready;
            int dc_st = (int)top->o_dcache_ctrl_state;
            int ws  = (int)top->o_l2_wr_state;
            int xws = (int)top->o_xbar_w_state;
            int upd = (int)top->o_dc_update_en;
            int rden = (int)top->o_dc_rd_en;
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
            // fill data capture: exactly when the dcache writes the refill line
            if (upd && upd != last_upd) {
                const uint32_t *lw = (const uint32_t *)top->o_adapt_rd_line;
                unsigned long long w0 = ((unsigned long long)lw[1] << 32) | lw[0];
                unsigned long long w1 = ((unsigned long long)lw[3] << 32) | lw[2];
                unsigned long long w2 = ((unsigned long long)lw[5] << 32) | lw[4];
                unsigned long long w3 = ((unsigned long long)lw[7] << 32) | lw[6];
                printf("[%5d] FILL line=0x%03lx w0=%016llx w1=%016llx w2=%016llx w3=%016llx\n",
                       w, (unsigned long)top->o_dc_rd_addr, w0, w1, w2, w3);
            }
            // load data capture: exactly when the cache serves a load
            if (rden && rden != last_rden) {
                printf("[%5d] LOAD addr=0x%03lx data=%016llx\n",
                       w, (unsigned long)top->o_dc_addr_lo,
                       (unsigned long long)top->o_dc_data_to_core);
            }
            last_upd = upd; last_rden = rden;
            // per-cycle dump around the GOT loads + BSS loop (cycles 108-220)
            if (w >= 108 && w <= 220) {
                const uint32_t *m31 = (const uint32_t *)top->o_dc_mem31;
                printf("[%5d] CYC st=%d rd=%d wr=%d addr=%03lx hit=%d upd=%d wren=%d repl=%d mwv=%d rden=%d ld=%016llx | "
                       "mwb_rd=%016llx rw=%d wb=%016llx sm=%d sw=%d | a4=%016llx a5=%016llx | "
                       "IFPC=%08lx iraw=%08x idec=%08x icmp=%d | ex=%08x mem=%08x pcx=%d fx=%d sx=%d tr=%d/%d taddr=%08lx\n",
                       w, (int)top->o_dcache_ctrl_state,
                       top->o_dc_i_read, top->o_dc_i_write,
                       (unsigned long)top->o_dc_addr_lo,
                       top->o_dc_tag_hit, top->o_dc_update_en,
                       top->o_dc_wr_en, top->o_dc_block_replace,
                       top->o_dc_mem_write_valid, top->o_dc_rd_en,
                       (unsigned long long)top->o_dc_data_to_core,
                       (unsigned long long)top->o_mwb_read_data,
                       top->o_mwb_regwrite,
                       (unsigned long long)top->o_result_wb,
                       top->o_hu_stall_mem, top->o_hu_stall_wb,
                       (unsigned long long)top->o_rf_a4,
                       (unsigned long long)top->o_rf_a5,
                       (unsigned long)top->o_if_pc,
                       (unsigned)top->o_instr_raw,
                       (unsigned)top->o_instr_dec,
                       top->o_instr_comp,
                       (unsigned)top->o_instr_ex,
                       (unsigned)top->o_instr_mem,
                       top->o_pcsrc_ex, top->o_hu_flush_ex, top->o_hu_stall_ex,
                       top->o_pc_cntrl_wb, top->o_trap_cntrl_wb,
                       (unsigned long)top->o_trap_addr_if);
            }
            tick();
        }
        printf("[TB] ---- end trace (printed %d changes) ----\n", printed);
    }
    printf("[TB] hart0 PC after boot trace = 0x%08lx\n",
           (unsigned long)top->o_hart0_pc);

    // NOTE: no TX bitstream capture here -- it would burn cycles and push the
    // banner drain below to start mid-frame (the drain's naive edge detection
    // would then lock onto data-bit falls, not start bits). The trace above
    // ends at cycle ~240 and the UART line is idle-high from reset until the
    // banner's first byte, so starting the drain here syncs it cleanly.

    // Let firmware boot: it prints a fixed banner before entering the loop:
    //   "\r\n=== GRX930 UART Echo Test ===\r\nReady. Waiting for commands...\r\n"
    // The banner transmission starts at ~cycle 400 (right after the BSS clear
    // + UART init) and takes ~66 * 10 * BIT_CYCLES cycles (~570K cycles).
    // The trace above ends at cycle ~240, so the TX line is still idle-high
    // here and the first falling edge the drain sees is the banner's genuine
    // start bit.  Drain byte-by-byte with a generous per-byte timeout.

    const char *BANNER = "\r\n=== GRX930 UART Echo Test ===\r\nReady. Waiting for commands...\r\n";
    size_t banner_len = strlen(BANNER);
    printf("[TB] waiting for boot banner (%zu bytes)...\n", banner_len);
    uint8_t b;
    bool banner_ok = true;
    int first_bad = -1;
    for (size_t i = 0; i < banner_len; i++) {
        if (!wait_for_tx_byte(&b, BIT_CYCLES * 200)) {
            printf("[TB] banner byte %zu: TIMEOUT\n", i);
            banner_ok = false;
            break;
        }
        if (b != (uint8_t)BANNER[i]) {
            if (first_bad < 0) first_bad = (int)i;
            printf("[TB] banner byte %zu mismatch: got 0x%02X ('%c') want 0x%02X ('%c')\n",
                   i, b, (b >= 32 && b < 127) ? b : '.',
                   (uint8_t)BANNER[i],
                   (BANNER[i] >= 32 && BANNER[i] < 127) ? BANNER[i] : '.');
            banner_ok = false;
            if (i > first_bad + 3) break;  // don't spam: show first 4 bad bytes
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

    // ---- debug: UART RX state + MMIO reads during the PING test ----
    printf("[TB] hart0 PC before PING = 0x%08lx  rx_state=%d rx_empty=%d\n",
           (unsigned long)top->o_hart0_pc,
           (int)top->o_uart_rx_state, top->o_uart_rx_fifo_empty);
    printf("Test: PING...\n");
    // Watch the RX FSM THROUGH the frame: start the watch before driving the
    // pin so every state transition of the 'P' frame is captured, plus any
    // baud-tick / stop-check events (we=1).  Also print the pin value the TB
    // is currently driving so we can see exactly what the UART samples.
    {
        int last_rxst = -1, last_re = -1, last_mrd = -1;
        int last_uart_rd = -1, last_uart_wr = -1, last_rxf_re = -1;
        int last_txst = -1;
        unsigned long last_pc = ~0UL;
        int frame_bit = -1;   // which bit the TB is currently driving (-1 idle)
        uint64_t bit_start = 0;
        auto frame_phase = [&](uint64_t t) {
            // returns (bit_index, cycles_into_bit) for the 10-bit frame
            uint64_t pos = t - bit_start;
            int idx = (int)(pos / BIT_CYCLES);
            return std::make_pair(idx < 0 ? -1 : idx, pos % BIT_CYCLES);
        };
        // Watch the frame + FIFO landing + pop (~8.5K cycles, ends at cycle
        // ~575,555).  The firmware writes the first "PONGA" byte at ~575,632
        // (TXWE), so ending here leaves the TB idle-listening on TX when the
        // reply starts -- a longer watch joins mid-frame and the start-bit
        // detection below locks onto data transitions (garbage decode).
        for (int w = 0; w < 8500; w++) {
            // drive the frame manually so the watch sees it
            if (w == 0) {
                bit_start = cycle;
                top->i_uart_rxd = 0;  // start bit
                frame_bit = 0;
            } else {
                auto ph = frame_phase(cycle);
                // Frame bits: 0=start, 1..8=data, 9=stop, >=10 idle-high.
                int want;
                if (ph.first >= 9) want = 1;                       // stop + idle
                else if (ph.first == 0) want = 0;                  // start
                else want = ('P' >> (ph.first - 1)) & 1;           // data
                top->i_uart_rxd = want;
                frame_bit = ph.first;
            }
            if (top->o_uart_rx_state != last_rxst || top->o_uart_rx_fifo_empty != last_re ||
                top->o_uart_rx_fifo_we) {
                auto ph = frame_phase(cycle);
                printf("[%5llu] RX st=%d bc=%u shift=0x%02x empty=%d we=%d wdata=0x%02x | "
                       "pin=%d drv=%d (bit %d, +%llu)\n",
                       (unsigned long long)cycle,
                       (int)top->o_uart_rx_state,
                       (unsigned)top->o_uart_rx_baud_cnt,
                       (unsigned)top->o_uart_rx_shift,
                       top->o_uart_rx_fifo_empty,
                       top->o_uart_rx_fifo_we,
                       (unsigned)top->o_uart_rx_fifo_wdata,
                       top->o_uart_rx_pin,
                       top->i_uart_rxd,
                       frame_bit,
                       (unsigned long long)(ph.first < 0 ? 0 : ph.second));
                last_rxst = top->o_uart_rx_state;
                last_re = top->o_uart_rx_fifo_empty;
            }
            // PAIRED UART-slave read response: addr+data latched together.
            // Log only state CHANGES so the window isn't flooded.
            int urd = (int)top->o_uart_axi_rd_valid;
            if (urd && !last_uart_rd) {
                printf("[%5llu] URD addr=0x%02x data=0x%016llx\n",
                       (unsigned long long)cycle,
                       (unsigned)top->o_uart_axi_rd_addr,
                       (unsigned long long)top->o_uart_axi_rd_data);
            }
            last_uart_rd = urd;
            // TX FIFO write (firmware pushing a byte): paired addr+data.
            int uwr = (int)top->o_uart_axi_wr_valid;
            if (uwr && !last_uart_wr) {
                printf("[%5llu] UWR addr=0x%02x data=0x%016llx\n",
                       (unsigned long long)cycle,
                       (unsigned)top->o_uart_axi_wr_addr,
                       (unsigned long long)top->o_uart_axi_wr_data);
            }
            last_uart_wr = uwr;
            // RX FIFO pop (rx_fifo_re pulse = a read consumed the byte)
            int rfr = (int)top->o_uart_rx_fifo_re;
            if (rfr && !last_rxf_re) {
                printf("[%5llu] RXPOP rdptr=%d\n", (unsigned long long)cycle,
                       (int)top->o_uart_rx_fifo_rd_ptr);
            }
            last_rxf_re = rfr;
            if (top->o_mmio_rd_req_raw && !last_mrd) {
                printf("[%5llu] MMRD core=%d addr=0x%016llx data=0x%016llx\n",
                       (unsigned long long)cycle,
                       (int)top->o_mmio_rd_core,
                       (unsigned long long)top->o_mmio_rd_addr_raw,
                       (unsigned long long)top->o_mmio_rd_data_raw);
            }
            last_mrd = top->o_mmio_rd_req_raw;
            // PC trace: print on change, only in the interesting range.
            unsigned long pc = (unsigned long)top->o_hart0_pc;
            if (pc != last_pc && cycle >= 575000ULL && cycle <= 576200ULL) {
                printf("[%5llu] PC=0x%04lx\n", (unsigned long long)cycle, pc);
                last_pc = pc;
            }
            // UART TX FIFO activity in the reply window.
            if (cycle >= 575400ULL && cycle <= 575800ULL) {
                if (top->o_uart_tx_fifo_we) {
                    printf("[%5llu] TXWE data=0x%02x empty=%d full=%d\n",
                           (unsigned long long)cycle,
                           (unsigned)top->o_uart_tx_fifo_wdata,
                           top->o_uart_tx_fifo_empty,
                           top->o_uart_tx_fifo_full);
                }
                if (top->o_uart_tx_state != last_txst) {
                    printf("[%5llu] TXST=%d\n", (unsigned long long)cycle,
                           (int)top->o_uart_tx_state);
                    last_txst = top->o_uart_tx_state;
                }
            }
            tick();
        }
        top->i_uart_rxd = 1;  // back to idle
        printf("[TB] after RX watch: hart0 PC = 0x%08lx rx_empty=%d rx_state=%d\n",
               (unsigned long)top->o_hart0_pc,
               top->o_uart_rx_fifo_empty, (int)top->o_uart_rx_state);
    }
    expect_response("PONGA", "PING -> PONGA");

    printf("Test: ECHO 'Hello'...\n");
    uart_send_byte('E');
    uart_send_byte(5);          // length
    uart_send_byte('H'); uart_send_byte('e'); uart_send_byte('l');
    uart_send_byte('l');
    // The last byte ('o') commits to the RX FIFO ~8,260 cycles into its
    // frame and the firmware echoes as soon as it has read all 5 data bytes,
    // so the reply overlaps the 'o' stop bit -- listen from the stop bit on.
    {
        std::string got = send_and_collect('o', 6, BIT_CYCLES * 200);
        bool ok = (got == "HelloA");
        printf("  %-32s %s  (got \"%s\")\n", "ECHO Hello -> HelloA",
               ok ? "PASS" : "FAIL", ok ? "HelloA" : got.c_str());
        if (!ok) failures++;
    }

    printf("Test: VERSION...\n");
    {
        std::string got = send_and_collect('V', 15, BIT_CYCLES * 200);
        bool ok = (got == "GRX930_ECHO_V1A");
        printf("  %-32s %s  (got \"%s\")\n", "VERSION -> GRX930_ECHO_V1A",
               ok ? "PASS" : "FAIL", ok ? "GRX930_ECHO_V1A" : got.c_str());
        if (!ok) failures++;
    }

    printf("Test: UNKNOWN CMD...\n");
    {
        // Firmware replies: "ERR_UNKNOWN_CMD" + hex8(cmd) + 'E' (cmd='X'=0x58)
        std::string got = send_and_collect('X', 18, BIT_CYCLES * 200);
        bool ok = (got == "ERR_UNKNOWN_CMD58E");
        printf("  %-32s %s  (got \"%s\")\n", "UNKNOWN -> ERR_UNKNOWN_CMD58E",
               ok ? "PASS" : "FAIL", ok ? "ERR_UNKNOWN_CMD58E" : got.c_str());
        if (!ok) failures++;
    }

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