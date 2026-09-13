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
 *      back over UART and compared against a software reference.  The test
 *      sweeps M/N/K across the NPU's supported ranges (M<=8, N<=12, K<=16)
 *      and every precision (INT8/INT16/FP16/BF16/INT4).
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

// Backdoor DDR read (the SoC's TB readback port).  This sees what the DDR
// memory array actually holds, bypassing the CPU's caches -- useful for
// separating "the DMA did not write C" from "the CPU read a stale copy".
static uint8_t ddr_rd_byte(uint32_t addr) {
    top->i_tb_rd_addr = addr;
    top->eval();
    return top->o_tb_rd_data;
}

static uint32_t ddr_rd_word(uint32_t addr) {
    return (uint32_t)ddr_rd_byte(addr)
         | ((uint32_t)ddr_rd_byte(addr + 1) << 8)
         | ((uint32_t)ddr_rd_byte(addr + 2) << 16)
         | ((uint32_t)ddr_rd_byte(addr + 3) << 24);
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
// GEMM case sweep
// ----------------------------------------------------------------------------
// The NPU accepts M<=8, N<=12, K<=16 (c930_soc_top MAX_M/MAX_N/MAX_K) and the
// precisions INT8(0)/INT16(1)/FP16(2)/BF16(3)/INT4(4); C always comes back as
// a 32-bit result (INT32, or FP32 for the float modes).  Operands are small
// integers, so every product and partial sum is exactly representable in all
// five formats and in the FP32 accumulator -- which lets one integer reference
// check every precision.
//
// A and B are packed little-endian at the firmware's fixed addresses
// (uart_gemm_test.c): one nibble per element for INT4 (low nibble first), one
// byte for INT8, two bytes for INT16/FP16/BF16.
// ============================================================================
static const uint32_t GEMM_A_ADDR = 0x9000;   // must match uart_gemm_test.c
static const uint32_t GEMM_B_ADDR = 0x9400;
static const uint32_t GEMM_C_ADDR = 0x9800;

// Pre-fill the C buffer with a sentinel so an element the NPU never writes
// reads back as 0xDEADBEEF instead of a stale value from an earlier case.
static void gemm_clear_c(int n_words) {
    for (int i = 0; i < n_words; i++) {
        preload_byte(GEMM_C_ADDR + i * 4 + 0, 0xEF);
        preload_byte(GEMM_C_ADDR + i * 4 + 1, 0xBE);
        preload_byte(GEMM_C_ADDR + i * 4 + 2, 0xAD);
        preload_byte(GEMM_C_ADDR + i * 4 + 3, 0xDE);
    }
}

struct GemmCase { int prec, m, n, k; };

static const char *prec_name(int p) {
    switch (p) {
        case 0: return "INT8";
        case 1: return "INT16";
        case 2: return "FP16";
        case 3: return "BF16";
        case 4: return "INT4";
        default: return "?";
    }
}

// float -> IEEE binary16 bits.  The operands are exact small integers, so this
// never needs to round or subnormalise.
static uint16_t half_bits_from_float(float f) {
    uint32_t x;
    memcpy(&x, &f, sizeof x);
    uint16_t sign = (uint16_t)((x >> 16) & 0x8000u);
    if ((x & 0x7FFFFFFFu) == 0) return sign;             // +/-0
    int exp = (int)((x >> 23) & 0xFFu) - 127 + 15;
    uint32_t man = x & 0x7FFFFFu;
    if (exp <= 0)  return sign;                          // flush tiny values
    if (exp >= 31) return (uint16_t)(sign | 0x7C00u);    // inf
    return (uint16_t)(sign | ((uint32_t)exp << 10) | (man >> 13));
}

// float -> bfloat16 bits (top half of the FP32 pattern; exact for the small
// integers used here, which fit bfloat16's 8-bit mantissa).
static uint16_t bf16_bits_from_float(float f) {
    uint32_t x;
    memcpy(&x, &f, sizeof x);
    return (uint16_t)(x >> 16);
}

static void gemm_store_elem(uint32_t base, uint32_t idx, int prec, int v) {
    if (prec == 0) {                       // INT8
        preload_byte(base + idx, (uint8_t)(int8_t)v);
        return;
    }
    if (prec == 4) return;                 // INT4: nibble-packed in a batch
    uint16_t u;                            // INT16 / FP16 / BF16
    if (prec == 1)      u = (uint16_t)(int16_t)v;
    else if (prec == 2) u = half_bits_from_float((float)v);
    else                u = bf16_bits_from_float((float)v);
    preload_byte(base + idx * 2, (uint8_t)(u & 0xFF));
    preload_byte(base + idx * 2 + 1, (uint8_t)(u >> 8));
}

// Write one row-major operand of n_elem elements to `base` for `prec`.
static void gemm_pack_operand(uint32_t base, const std::vector<int> &vals, int prec) {
    const uint32_t n_elem = (uint32_t)vals.size();
    if (prec == 4) {
        for (uint32_t i = 0; i < n_elem; i += 2) {
            uint8_t lo = (uint8_t)(vals[i] & 0xF);
            uint8_t hi = (i + 1 < n_elem) ? (uint8_t)(vals[i + 1] & 0xF) : 0;
            preload_byte(base + i / 2, (uint8_t)(lo | (hi << 4)));
        }
        return;
    }
    for (uint32_t i = 0; i < n_elem; i++) gemm_store_elem(base, i, prec, vals[i]);
}

// Run one GEMM case: pack A/B, send 'G' prec M N K, collect C + ACK, compare
// against the integer reference.  On failure `why` gets a one-line reason.
static bool run_gemm_case(const GemmCase &c, std::string &why) {
    const int M = c.m, N = c.n, K = c.k;
    std::vector<int> a((size_t)M * K), b((size_t)K * N);
    for (size_t i = 0; i < a.size(); i++) a[i] = (int)((i * 3 + 1) % 9) - 4;  // -4..4
    for (size_t i = 0; i < b.size(); i++) b[i] = (int)((i * 5 + 2) % 9) - 4;

    gemm_pack_operand(GEMM_A_ADDR, a, c.prec);
    gemm_pack_operand(GEMM_B_ADDR, b, c.prec);
    gemm_clear_c(M * N);

    // DEBUG: verify the preloaded operands round-trip through the DDR
    // backdoor (pack/unpack sanity for the float formats).
    if (getenv("TB_DEBUG_PACK")) {
        printf("    [pack] prec=%d A[0..5] ddr:", c.prec);
        for (int i = 0; i < 6; i++) {
            uint32_t w = ddr_rd_word(GEMM_A_ADDR + i * (c.prec == 0 || c.prec == 4 ? 1 : 2));
            printf(" %04x", w & 0xFFFF);
        }
        printf("\n    [pack] want  A[0..5]   :");
        for (int i = 0; i < 6; i++) {
            int v = a[(size_t)i];
            uint16_t u = (c.prec == 2) ? half_bits_from_float((float)v)
                                       : (c.prec == 3) ? bf16_bits_from_float((float)v) : 0;
            printf(" %04x", u);
        }
        printf("\n");
    }

    uint8_t cmd[5] = { 'G', (uint8_t)c.prec, (uint8_t)M, (uint8_t)N, (uint8_t)K };
    std::string got = send_bytes_collect(cmd, 5, M * N * 4 + 1, BIT_CYCLES * 400);

    if (got.size() != (size_t)(M * N * 4 + 1)) {
        char buf[80];
        snprintf(buf, sizeof buf, "short reply: %zu of %d bytes",
                 got.size(), M * N * 4 + 1);
        why = buf;
        return false;
    }
    if (got.back() != 'A') {
        char buf[80];
        snprintf(buf, sizeof buf, "bad ACK 0x%02x", (uint8_t)got.back());
        why = buf;
        return false;
    }

    int nbad = 0;
    char first[3][72];
    for (int i = 0; i < M * N; i++) {
        const int m = i / N, n = i % N;
        int32_t ref = 0;
        for (int k = 0; k < K; k++) ref += a[(size_t)m * K + k] * b[(size_t)k * N + n];
        uint32_t raw = (uint32_t)(uint8_t)got[i * 4 + 0]
                     | ((uint32_t)(uint8_t)got[i * 4 + 1] << 8)
                     | ((uint32_t)(uint8_t)got[i * 4 + 2] << 16)
                     | ((uint32_t)(uint8_t)got[i * 4 + 3] << 24);
        bool ok;
        if (c.prec == 2 || c.prec == 3) {   // FP16/BF16 -> C is FP32
            float f;
            memcpy(&f, &raw, sizeof f);
            ok = (f == (float)ref);
        } else {
            ok = ((int32_t)raw == ref);
        }
        if (!ok) {
            if (nbad < 3) {
                const char *tag = (raw == 0xDEADBEEFu) ? " [not written]" : "";
                snprintf(first[nbad], sizeof first[0], "C[%d] got 0x%08x want %d%s",
                         i, raw, ref, tag);
            }
            nbad++;
        }
    }
    if (nbad) {
        // DIAGNOSTIC: classify each mismatching element.  A row that is correct
        // in the DDR array but wrong in the CPU's stream means the read path
        // served a stale copy (cache coherency); a row that is stale in DDR too
        // means the DMA never wrote it.
        auto elem_ref = [&](int i) -> int32_t {
            const int m = i / N, n = i % N;
            int32_t r = 0;
            for (int k = 0; k < K; k++) r += a[(size_t)m * K + k] * b[(size_t)k * N + n];
            return r;
        };
        int ddr_bad = 0, ddr_bad_uart_ok = 0;
        printf("    [diag] case %s %dx%dx%d  M*N=%d\n", prec_name(c.prec), M, N, K, M * N);
        for (int i = 0; i < M * N; i++) {
            uint32_t d = ddr_rd_word(GEMM_C_ADDR + i * 4);
            uint32_t u = (uint32_t)(uint8_t)got[i * 4 + 0]
                       | ((uint32_t)(uint8_t)got[i * 4 + 1] << 8)
                       | ((uint32_t)(uint8_t)got[i * 4 + 2] << 16)
                       | ((uint32_t)(uint8_t)got[i * 4 + 3] << 24);
            // The reference has no meaning for the float modes (C is FP32 bits)
            // beyond zero/nonzero, so classify by DDR-vs-UART only there.
            bool ddr_ok, uart_ok;
            if (c.prec == 2 || c.prec == 3) {
                float fd, fu;
                memcpy(&fd, &d, sizeof fd);
                memcpy(&fu, &u, sizeof fu);
                ddr_ok = (fd == (float)elem_ref(i));
                uart_ok = (fu == (float)elem_ref(i));
            } else {
                ddr_ok = ((int32_t)d == elem_ref(i));
                uart_ok = ((int32_t)u == elem_ref(i));
            }
            if (!ddr_ok) { ddr_bad++; if (uart_ok) ddr_bad_uart_ok++; }
            if (i < 24)
                printf("    [diag] %2d: ddr=0x%08x(%s) uart=0x%08x(%s) ref=%d\n",
                       i, d, ddr_ok ? "ok " : "BAD", u, uart_ok ? "ok " : "BAD",
                       (int)elem_ref(i));
        }
        printf("    [diag] ddr wrong %d/%d; uart wrong %d/%d; ddr-wrong-but-uart-ok %d\n",
               ddr_bad, M * N, nbad, M * N, ddr_bad_uart_ok);

        char idxs[400] = "";
        size_t p = 0;
        int shown = 0;
        for (int i = 0; i < M * N && shown < 48; i++) {
            const int m = i / N, n = i % N;
            int32_t ref = 0;
            for (int k = 0; k < K; k++) ref += a[(size_t)m * K + k] * b[(size_t)k * N + n];
            uint32_t raw = (uint32_t)(uint8_t)got[i * 4 + 0]
                         | ((uint32_t)(uint8_t)got[i * 4 + 1] << 8)
                         | ((uint32_t)(uint8_t)got[i * 4 + 2] << 16)
                         | ((uint32_t)(uint8_t)got[i * 4 + 3] << 24);
            bool bad = (c.prec == 2 || c.prec == 3) ? false : ((int32_t)raw != ref);
            if (c.prec == 2 || c.prec == 3) {
                float f; memcpy(&f, &raw, sizeof f);
                bad = !(f == (float)ref);
            }
            if (bad) {
                int w = snprintf(idxs + p, sizeof idxs - p, "%s%d", shown ? "," : "", i);
                if (w > 0) p += (size_t)w;
                shown++;
            }
        }
        char buf[640];
        snprintf(buf, sizeof buf, "%d/%d wrong at [%s%s]; %s",
                 nbad, M * N, idxs, nbad > shown ? ",..." : "", first[0]);
        why = buf;
        return false;
    }
    return true;
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
        // INT8 sweep across the NPU's supported ranges (M<=8, N<=12, K<=16),
        // then every precision at a small and a mid shape.
        static const GemmCase CASES[] = {
            { 0, 1,  1,  1 }, { 0, 1,  1, 16 }, { 0, 1, 12,  8 }, { 0, 2,  3,  5 },
            { 0, 4,  4,  4 }, { 0, 5,  7,  9 }, { 0, 8,  1,  4 }, { 0, 8,  4,  1 },
            { 0, 8, 12, 16 }, { 0, 3,  9, 11 },
            { 1, 4,  4,  4 }, { 2, 4,  4,  4 }, { 3, 4,  4,  4 }, { 4, 4,  4,  4 },
            { 1, 2,  3,  5 }, { 2, 2,  3,  5 }, { 3, 2,  3,  5 }, { 4, 2,  3,  5 },
        };
        const int ncase = (int)(sizeof CASES / sizeof CASES[0]);
        int cpass = 0;
        for (int ci = 0; ci < ncase; ci++) {
            const GemmCase &c = CASES[ci];
            std::string why;
            bool ok = run_gemm_case(c, why);
            char label[64];
            snprintf(label, sizeof label, "GEMM %-5s %2dx%2dx%2d",
                     prec_name(c.prec), c.m, c.n, c.k);
            if (ok) {
                printf("  %-32s PASS\n", label);
                cpass++;
            } else {
                printf("  %-32s FAIL  %s\n", label, why.c_str());
                failures++;
            }
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
