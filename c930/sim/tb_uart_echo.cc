/**
 * tb_uart_echo.cc -- UART echo testbench for the GRX930 single-core SoC
 * Verilator model (c930_soc_verilator.sv).
 *
 * Flow:
 *   1. Preload the echo firmware hex into DDR (addr 0) via the TB preload port.
 *   2. Release reset; the RV64IMAC core boots from PC=0 and runs the echo loop.
 *   3. Drive i_uart_rxd with real 115200-baud frames (start + 8N1).
 *   4. Sample o_uart_txd at mid-bit to capture the firmware's replies.
 *   5. Verify PING / ECHO / VERSION / UNKNOWN responses.
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
// mid-reply-frame and decode garbage.
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
// Main
// ============================================================================
static int failures = 0;

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

    // 2b. Sanity: verify the preload landed
    {
        auto rd = [&](uint32_t a) -> uint8_t {
            top->i_tb_rd_addr = a; top->eval(); return top->o_tb_rd_data;
        };
        printf("[TB] DDR[0..7] = %02x %02x %02x %02x %02x %02x %02x %02x (want 37 81 00 00 ef 00 e0 27)\n",
               rd(0), rd(1), rd(2), rd(3), rd(4), rd(5), rd(6), rd(7));
    }

    // Let firmware boot: it prints a fixed banner before entering the loop:
    //   "\r\n=== GRX930 UART Echo Test ===\r\nReady. Waiting for commands...\r\n"
    // The banner transmission starts at ~cycle 400 (right after the BSS clear
    // + UART init) and takes ~66 * 10 * BIT_CYCLES cycles (~570K cycles).
    // The TX line is idle-high until the banner's first byte, so the first
    // falling edge the drain sees is the banner's genuine start bit.  Drain
    // byte-by-byte with a generous per-byte timeout.

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

    printf("Test: PING...\n");
    {
        std::string got = send_and_collect('P', 5, BIT_CYCLES * 200);
        bool ok = (got == "PONGA");
        printf("  %-32s %s  (got \"%s\")\n", "PING -> PONGA",
               ok ? "PASS" : "FAIL", ok ? "PONGA" : got.c_str());
        if (!ok) failures++;
    }

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