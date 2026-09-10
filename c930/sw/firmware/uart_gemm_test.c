/**
 * GRX930 UART GEMM Test Firmware
 *
 * Extends the UART echo protocol with an NPU GEMM command.  The host
 * preloads the A and B matrices into DDR (via the testbench preload port at
 * the fixed addresses below), then sends:
 *
 *   'G' prec M N K
 *
 *   prec : precision byte (0 = INT8, see c930_npu_csr.sv PREC)
 *   M    : output rows,     1..8
 *   N    : output cols,     1..12
 *   K    : reduction length,1..16
 *
 * The firmware programs the NPU CSRs, waits for completion, and replies with
 * C = A x B as M*N little-endian INT32 elements followed by an 'A' ACK:
 *
 *   C[0..M*N*4-1] 'A'
 *
 * A is M*K bytes row-major, B is K*N bytes row-major, C is M*N INT32
 * row-major -- the exact layout the NPU DMA expects (c930_npu_core.sv).
 *
 * Fixed DDR buffer addresses (must match the host preload):
 *   A -> 0x9000, B -> 0x9400, C -> 0x9800
 * These live well above the sim firmware (link_sim.ld: RAM 0x0..0x8000,
 * stack top 0x8000) and below the 64 KB DDR model.
 *
 * Build (sim, Verilator SoC -- core boots at PC=0):
 *   make TARGET=uart_gemm_test ASM_SRCS=start_sim.S \
 *        LDFLAGS="-T link_sim.ld -nostdlib -nostartfiles -static -Wl,--gc-sections"
 */

#include <stdint.h>
#include <stddef.h>

// ============================================================================
// UART (c930_uart.sv, AXI4-Lite slave at 0x4000_1000)
// ============================================================================
#define UART_BASE       0x40001000ULL

#define UART_TX_REG     (*(volatile uint32_t*)(UART_BASE + 0x00))  // W: TX data
#define UART_RX_REG     (*(volatile uint32_t*)(UART_BASE + 0x04))  // R: RX data
#define UART_STATUS_REG (*(volatile uint32_t*)(UART_BASE + 0x08))  // R: status
#define UART_CTRL_REG   (*(volatile uint32_t*)(UART_BASE + 0x0C))  // R/W: baud divisor

#define UART_TX_FULL    (1 << 0)  // TX FIFO full
#define UART_RX_EMPTY   (1 << 1)  // RX FIFO empty
#define UART_TX_DONE    (1 << 2)  // TX shift register done

#define UART_DIV_115200 53        // 100 MHz -> ~115740 baud

// ============================================================================
// NPU0 CSR (c930_npu_csr.sv at 0x4000_0000, via MMIO bridge)
// ============================================================================
#define NPU0_BASE       0x40000000ULL
#define NPU_CTRL        (*(volatile uint32_t*)(NPU0_BASE + 0x00))  // W: [0] START
#define NPU_STATUS      (*(volatile uint32_t*)(NPU0_BASE + 0x04))  // R: [0] BUSY [1] DONE [2] ERROR
#define NPU_DIM_M       (*(volatile uint32_t*)(NPU0_BASE + 0x08))
#define NPU_DIM_N       (*(volatile uint32_t*)(NPU0_BASE + 0x0c))
#define NPU_DIM_K       (*(volatile uint32_t*)(NPU0_BASE + 0x10))
#define NPU_A_BASE      (*(volatile uint32_t*)(NPU0_BASE + 0x14))
#define NPU_B_BASE      (*(volatile uint32_t*)(NPU0_BASE + 0x18))
#define NPU_C_BASE      (*(volatile uint32_t*)(NPU0_BASE + 0x1c))
#define NPU_PREC        (*(volatile uint32_t*)(NPU0_BASE + 0x20))

#define NPU_STATUS_BUSY 0x1
#define NPU_STATUS_DONE 0x2
#define NPU_STATUS_ERROR 0x4

#define NPU_CTRL_START  0x1

// ---- GEMM buffer addresses in DDR (host preloads A and B here) ----
#define GEMM_A_ADDR     0x9000
#define GEMM_B_ADDR     0x9400
#define GEMM_C_ADDR     0x9800

// ---- Hardware limits (c930_soc_top.sv defaults) ----
#define GEMM_MAX_M      8
#define GEMM_MAX_N      12
#define GEMM_MAX_K      16

// ============================================================================
// UART driver
// ============================================================================
void uart_init(void) {
    UART_CTRL_REG = UART_DIV_115200;
}

void uart_write_char(uint8_t c) {
    while (UART_STATUS_REG & UART_TX_FULL);
    UART_TX_REG = c;
}

uint8_t uart_read_char(void) {
    while (UART_STATUS_REG & UART_RX_EMPTY);
    return (uint8_t)(UART_RX_REG & 0xFF);
}

int uart_rx_available(void) {
    return !(UART_STATUS_REG & UART_RX_EMPTY);
}

void uart_write_string(const char* str) {
    while (*str) {
        uart_write_char(*str++);
    }
}

void uart_write_hex8(uint8_t val) {
    const char hex[] = "0123456789ABCDEF";
    uart_write_char(hex[(val >> 4) & 0x0F]);
    uart_write_char(hex[val & 0x0F]);
}

// ============================================================================
// NPU GEMM
// ============================================================================

// Run one GEMM on preloaded A/B buffers.  Returns 0 on success, -1 on bad
// dims (replies with an error string).  On success replies with C bytes
// followed by 'A'.
void handle_gemm(void) {
    uint8_t prec = uart_read_char();
    uint8_t m    = uart_read_char();
    uint8_t n    = uart_read_char();
    uint8_t k    = uart_read_char();

    if (m < 1 || m > GEMM_MAX_M ||
        n < 1 || n > GEMM_MAX_N ||
        k < 1 || k > GEMM_MAX_K) {
        uart_write_string("ERR_DIM");
        uart_write_char('E');
        return;
    }

    // Program the CSRs.  A/B/C bases are the fixed preloaded DDR addresses.
    NPU_DIM_M  = m;
    NPU_DIM_N  = n;
    NPU_DIM_K  = k;
    NPU_A_BASE = GEMM_A_ADDR;
    NPU_B_BASE = GEMM_B_ADDR;
    NPU_C_BASE = GEMM_C_ADDR;
    NPU_PREC   = prec;

    // START snapshots the CSRs into the queue and clears DONE/ERROR.
    NPU_CTRL = NPU_CTRL_START;

    // Single command: DONE (latched, cleared by START) then BUSY drop.
    while (!(NPU_STATUS & NPU_STATUS_DONE));
    while (NPU_STATUS & NPU_STATUS_BUSY);

    // Stream C = M*N little-endian INT32 elements, then ACK.
    uint32_t total = (uint32_t)m * n * 4;
    uint8_t *c = (uint8_t *)(uintptr_t)GEMM_C_ADDR;
    for (uint32_t i = 0; i < total; i++) {
        uart_write_char(c[i]);
    }
    uart_write_char('A');
}

// ============================================================================
// Command processor
// ============================================================================
#define CMD_ECHO    'E'
#define CMD_GEMM    'G'
#define CMD_PING    'P'
#define CMD_VERSION 'V'

// Echo back received data + 'A' -- same as the echo firmware, so the shared
// testbench's ECHO test holds for this firmware too.
void handle_echo(void) {
    uint8_t len = uart_read_char();
    uint8_t buf[255];
    for (uint8_t i = 0; i < len; i++) {
        buf[i] = uart_read_char();
    }
    for (uint8_t i = 0; i < len; i++) {
        uart_write_char(buf[i]);
    }
    uart_write_char('A');
}

void handle_ping(void) {
    uart_write_string("PONG");
    uart_write_char('A');
}

void handle_version(void) {
    // Keep the echo firmware's reply so the shared testbench expectations
    // hold (this firmware is a superset of the echo protocol).
    uart_write_string("GRX930_ECHO_V1");
    uart_write_char('A');
}

void process_command(void) {
    uint8_t cmd = uart_read_char();

    switch (cmd) {
        case CMD_ECHO:
            handle_echo();
            break;

        case CMD_GEMM:
            handle_gemm();
            break;

        case CMD_PING:
            handle_ping();
            break;

        case CMD_VERSION:
            handle_version();
            break;

        default:
            uart_write_string("ERR_UNKNOWN_CMD");
            uart_write_hex8(cmd);
            uart_write_char('E');
            break;
    }
}

// ============================================================================
// Startup
// ============================================================================
extern uint32_t _bss_start;
extern uint32_t _bss_end;

void startup_c(void) {
    // Clear BSS
    uint32_t* bss = &_bss_start;
    uint32_t* bss_end = &_bss_end;
    while (bss < bss_end) {
        *bss++ = 0;
    }

    // Initialize UART (115200 baud)
    uart_init();

    // Announce boot -- same banner as the echo firmware so the shared
    // testbench's banner drain stays byte-exact.
    uart_write_string("\r\n=== GRX930 UART Echo Test ===\r\n");
    uart_write_string("Ready. Waiting for commands...\r\n");

    // Main loop
    while (1) {
        if (uart_rx_available()) {
            process_command();
        }
    }
}