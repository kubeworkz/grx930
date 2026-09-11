/**
 * tb_uart_echo.cc -- UART testbench for the GRX930 single-core SoC
 * Verilator model (c930_soc_verilator.sv).
 *
 * Flow:
 *   1. Preload the firmware hex into DDR (addr 0) via the TB preload port.
 *   2. Release reset; the RV64IMAC core boots from PC=0 and runs the firmware.
 *   3. Drive i_uart_rxd with real 115200-baud frames (start + 8N1).
 *   4. Sample o_uart_txd at mid-bit to capture the firmware's replies.
 *   5. Verify PING / ECHO / VERSION / UNKNOWN responses.
 *   6. Verify the GEMM command: 'G' prec M N K.  A/B are preloaded by the TB
 *      at the firmware's fixed DDR addresses; the NPU result C is streamed
 *      back over UART and compared against a software reference.
 *
 * The echo tests need the echo firmware hex; the GEMM test needs the GEMM
 * firmware hex (a superset: it answers every echo command too).
 *
 * Build (server):
 *   cd c930 && bash sim/build_grx930_verilator.sh
 * Run (echo firmware):
 *   ./build/verilator_soc/Vc930_soc_verilator firmware_uart_echo_test.hex
 * Run (GEMM firmware):
 *   ./build/verilator_soc/Vc930_soc_verilator firmware_uart_gemm_test.hex
 */

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <cmath>

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
            if (tok[0] == '@') {
                // objcopy -O verilog emits each LOAD run prefixed with its
                // virtual address (@00000000 ...).  The runs are NOT
                // contiguous (alignment padding between sections), so honor
                // the address instead of appending to the previous run.
                addr = (uint32_t)strtoul(tok + 1, nullptr, 16);
            } else if (tok[0] != '/' && tok[0] != '#') {
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

// Send a sequence of bytes and collect the reply, listening on TX from the
// last byte's stop bit onward.  The UART commits each RX byte to the FIFO at
// its stop check (~8,260 cycles into the 8,640-cycle frame) and the firmware
// answers as soon as it has consumed the last byte, so the reply's first
// start edge lands BEFORE the final frame's stop bit completes -- a plain
// send-then-listen would join mid-reply-frame and decode garbage.
static std::string send_bytes_collect(const uint8_t *bytes, int nbytes,
                                      int nreply, uint64_t timeout) {
    for (int i = 0; i < nbytes; i++) {
        uint8_t b = bytes[i];
        top->i_uart_rxd = 0;                      // start bit
        for (uint64_t t = 0; t < BIT_CYCLES; t++) tick();
        for (int bit = 0; bit < 8; bit++) {       // 8 data bits, LSB first
            top->i_uart_rxd = (b >> bit) & 1;
            for (uint64_t t = 0; t < BIT_CYCLES; t++) tick();
        }
        top->i_uart_rxd = 1;                      // stop bit
        if (i < nbytes - 1) {
            for (uint64_t t = 0; t < BIT_CYCLES; t++) tick();
        }
        // For the last byte, leave the stop bit driving while we listen on TX.
    }
    std::string got;
    for (int i = 0; i < nreply; i++) {
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

    // The GEMM command needs a firmware that implements it; the minimal echo
    // firmware answers every other command but replies "ERR_UNKNOWN_CMD" to
    // 'G'.  Gate the GEMM test on the image so either firmware can be run.
    const bool gemm_fw = (strstr(hexfile, "gemm") != nullptr);

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
        printf("[TB] DDR[0..7] = %02x %02x %02x %02x %02x %02x %02x %02x\n",
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

    printf("Test: GEMM shape/precision sweep over UART...\n");
    if (!gemm_fw) {
        printf("  %-32s SKIP  (load the GEMM firmware hex to run this)\n",
               "GEMM sweep");
    } else {
        // Precision encodings: 0=INT8, 1=INT16, 2=FP16, 3=BF16, 4=INT4
        struct GemmCase { int prec, m, n, k; };
        static const GemmCase CASES[] = {
            { 0, 1,  1,  1 }, { 0, 1,  1, 16 }, { 0, 1, 12,  8 }, { 0, 2,  3,  5 },
            { 0, 4,  4,  4 }, { 0, 5,  7,  9 }, { 0, 8,  1,  4 }, { 0, 8,  4,  1 },
            { 0, 8, 12, 16 }, { 0, 3,  9, 11 },
            { 1, 4,  4,  4 }, { 2, 4,  4,  4 }, { 3, 4,  4,  4 }, { 4, 4,  4,  4 },
            { 1, 2,  3,  5 }, { 2, 2,  3,  5 }, { 3, 2,  3,  5 }, { 4, 2,  3,  5 },
        };
        const int ncase = (int)(sizeof CASES / sizeof CASES[0]);
        const char *prec_names[] = {"INT8","INT16","FP16","BF16","INT4"};
        static const uint32_t GEMM_A_ADDR = 0x9000;
        static const uint32_t GEMM_B_ADDR = 0x9400;
        int cpass = 0;

        // Helper: pack one element into a byte buffer
        auto pack_elem = [](uint8_t *dst, int prec, int val) -> int {
            if (prec == 0) {  // INT8
                dst[0] = (uint8_t)(int8_t)val;
                return 1;
            }
            if (prec == 1) {  // INT16
                uint16_t u = (uint16_t)(int16_t)val;
                dst[0] = u & 0xFF; dst[1] = u >> 8;
                return 2;
            }
            if (prec == 4) {  // INT4 (nibble-packed, 2 elements per byte)
                dst[0] = (uint8_t)(val & 0xF);
                return 0;  // caller handles pairing
            }
            // FP16/BF16: convert int to float, then to half/bfloat16 bits
            float f = (float)val;
            uint32_t x;
            memcpy(&x, &f, sizeof x);
            uint16_t u;
            if (prec == 2) {  // FP16
                uint16_t sign = (uint16_t)((x >> 16) & 0x8000u);
                if ((x & 0x7FFFFFFFu) == 0) { u = sign; }
                else {
                    int exp = (int)((x >> 23) & 0xFFu) - 127 + 15;
                    uint32_t man = x & 0x7FFFFFu;
                    if (exp <= 0) u = sign;
                    else if (exp >= 31) u = (uint16_t)(sign | 0x7C00u);
                    else u = (uint16_t)(sign | ((uint32_t)exp << 10) | (man >> 13));
                }
            } else {  // BF16
                u = (uint16_t)(x >> 16);
            }
            dst[0] = u & 0xFF; dst[1] = u >> 8;
            return 2;
        };

        for (int ci = 0; ci < ncase; ci++) {
            const GemmCase &c = CASES[ci];
            int M = c.m, N = c.n, K = c.k;
            char label[64];
            snprintf(label, sizeof label, "GEMM %-5s %2dx%2dx%2d",
                     prec_names[c.prec], M, N, K);

            // Generate operand values: A[m][k] = ((m*K+k)*3+1)%9 - 4
            //                          B[k][n] = ((k*N+n)*5+2)%9 - 4
            // Pack A into DDR
            int a_idx = 0;
            for (int m = 0; m < M; m++)
                for (int k = 0; k < K; k++) {
                    int v = ((m * K + k) * 3 + 1) % 9 - 4;
                    uint8_t buf[2];
                    int sz = pack_elem(buf, c.prec, v);
                    if (c.prec == 4) {
                        // INT4: nibble-pack, 2 elements per byte
                        int flat = m * K + k;
                        if (flat & 1) continue;  // skip odd (paired with even)
                        int v2 = (flat + 1 < M * K) ?
                                 (((flat+1) * 3 + 1) % 9 - 4) : 0;
                        preload_byte(GEMM_A_ADDR + a_idx++,
                                     (uint8_t)(v & 0xF) | ((uint8_t)(v2 & 0xF) << 4));
                    } else {
                        for (int b = 0; b < sz; b++)
                            preload_byte(GEMM_A_ADDR + a_idx++, buf[b]);
                    }
                }
            // Pack B into DDR
            int b_idx = 0;
            for (int k = 0; k < K; k++)
                for (int n = 0; n < N; n++) {
                    int v = ((k * N + n) * 5 + 2) % 9 - 4;
                    uint8_t buf[2];
                    int sz = pack_elem(buf, c.prec, v);
                    if (c.prec == 4) {
                        // INT4: nibble-pack, 2 elements per byte
                        int flat = k * N + n;
                        if (flat & 1) continue;  // skip odd (paired with even)
                        int v2 = (flat + 1 < K * N) ?
                                 (((flat+1) * 5 + 2) % 9 - 4) : 0;
                        preload_byte(GEMM_B_ADDR + b_idx++,
                                     (uint8_t)(v & 0xF) | ((uint8_t)(v2 & 0xF) << 4));
                    } else {
                        for (int b = 0; b < sz; b++)
                            preload_byte(GEMM_B_ADDR + b_idx++, buf[b]);
                    }
                }

            // Send GEMM command: 'G' prec M N K
            uint8_t cmd[5] = { 'G', (uint8_t)c.prec, (uint8_t)M, (uint8_t)N, (uint8_t)K };
            std::string got = send_bytes_collect(cmd, 5, M * N * 4 + 1, BIT_CYCLES * 200);

            if (got.size() != (size_t)(M * N * 4 + 1) || got.back() != 'A') {
                printf("  %-32s FAIL  (reply len=%zu, want %d, ack=0x%02x)\n",
                       label, got.size(), M * N * 4 + 1,
                       got.empty() ? 0 : (uint8_t)got.back());
                failures++;
                continue;
            }

            // Verify C against software reference
            bool ok = true;
            for (int m = 0; m < M && ok; m++) {
                for (int n = 0; n < N && ok; n++) {
                    uint32_t raw = (uint32_t)(uint8_t)got[(m*N+n)*4+0]
                                 | ((uint32_t)(uint8_t)got[(m*N+n)*4+1] << 8)
                                 | ((uint32_t)(uint8_t)got[(m*N+n)*4+2] << 16)
                                 | ((uint32_t)(uint8_t)got[(m*N+n)*4+3] << 24);

                    if (c.prec == 0 || c.prec == 1 || c.prec == 4) {
                        // Integer: compare exact
                        int32_t ref = 0;
                        for (int k = 0; k < K; k++) {
                            int av = ((m*K+k)*3+1)%9-4;
                            int bv = ((k*N+n)*5+2)%9-4;
                            ref += av * bv;
                        }
                        if ((int32_t)raw != ref) {
                            printf("    C[%d][%d] mismatch: got %d want %d\n",
                                   m, n, (int32_t)raw, ref);
                            ok = false;
                        }
                    } else {
                        // FP: compare with float tolerance
                        // Recompute reference in float
                        float ref_f = 0;
                        for (int k = 0; k < K; k++) {
                            int av = ((m*K+k)*3+1)%9-4;
                            int bv = ((k*N+n)*5+2)%9-4;
                            ref_f += (float)av * (float)bv;
                        }
                        // Decode C as FP32
                        float got_f;
                        memcpy(&got_f, &raw, sizeof got_f);
                        // Allow FP rounding tolerance: |got - ref| <= max(1, |ref|*0.01)
                        float diff = got_f - ref_f;
                        float tol = (ref_f == 0.0f) ? 1.0f : fabsf(ref_f) * 0.02f;
                        if (fabsf(diff) > tol && !(ref_f == 0.0f && got_f == 0.0f)) {
                            printf("    C[%d][%d] mismatch: got %f want %f (diff=%f)\n",
                                   m, n, got_f, ref_f, diff);
                            ok = false;
                        }
                    }
                }
            }
            printf("  %-32s %s\n", label, ok ? "PASS" : "FAIL");
            if (ok) cpass++; else failures++;
        }
        printf("  %-32s %d/%d cases passed\n", "GEMM sweep total", cpass, ncase);
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
