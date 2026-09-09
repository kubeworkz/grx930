/**
 * GRX930 UART Echo Test Firmware
 *
 * Minimal firmware to validate the UART communication channel.
 * Reads bytes from UART and echoes them back immediately.
 *
 * Usage:
 *   1. Flash firmware to GRX930
 *   2. Open serial terminal at 115200 baud
 *   3. Type characters — they should echo back
 *
 * Test commands (from host):
 *   'E' + data → Echo data back
 *   'P'       → Ping (responds with 'PONG')
 *   'V'       → Version (responds with 'GRX930_ECHO_V1')
 *   'T'       → Toggle LED (if available)
 *   'R'       → Reset
 *
 * Build:
 *   make CROSS_COMPILE=riscv64-linux-gnu- TARGET=uart_echo_test
 */

#include <stdint.h>
#include <stddef.h>

// ============================================================================
// Hardware Register Map (c930_uart.sv, AXI4-Lite slave at 0x4000_1000)
// ============================================================================
#define UART_BASE       0x40001000ULL

// UART registers (offsets per c930_uart.sv)
#define UART_TX_REG     (*(volatile uint32_t*)(UART_BASE + 0x00))  // W: TX data
#define UART_RX_REG     (*(volatile uint32_t*)(UART_BASE + 0x04))  // R: RX data
#define UART_STATUS_REG (*(volatile uint32_t*)(UART_BASE + 0x08))  // R: status
#define UART_CTRL_REG   (*(volatile uint32_t*)(UART_BASE + 0x0C))  // R/W: CTRL[15:0] = baud divisor
#define UART_IRQ_EN_REG (*(volatile uint32_t*)(UART_BASE + 0x10))  // R/W: IRQ enables

// Status register bits (c930_uart.sv)
#define UART_TX_FULL    (1 << 0)  // TX FIFO full
#define UART_RX_EMPTY   (1 << 1)  // RX FIFO empty
#define UART_TX_DONE    (1 << 2)  // TX shift register done

// Control register: CTRL[15:0] = baud divisor (baud = clk/(div+1)/16).
// Default divisor (100 MHz -> 115200) is 53; no enable bits exist.
#define UART_DIV_115200 53

// ============================================================================
// UART Driver
// ============================================================================

void uart_init(void) {
    // Set the baud divisor explicitly (default is already 53 @ 100 MHz).
    UART_CTRL_REG = UART_DIV_115200;
}

void uart_write_char(uint8_t c) {
    // Wait until the TX FIFO has space (bit0 = TX full)
    while (UART_STATUS_REG & UART_TX_FULL);
    UART_TX_REG = c;
}

uint8_t uart_read_char(void) {
    // Wait until RX data is available (bit1 = RX empty)
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

void uart_write_hex32(uint32_t val) {
    uart_write_hex8((val >> 24) & 0xFF);
    uart_write_hex8((val >> 16) & 0xFF);
    uart_write_hex8((val >> 8) & 0xFF);
    uart_write_hex8(val & 0xFF);
}

// ============================================================================
// Test Commands
// ============================================================================

#define CMD_ECHO    'E'   // Echo back received data
#define CMD_PING    'P'   // Respond with "PONG"
#define CMD_VERSION 'V'   // Respond with version string
#define CMD_LED     'T'   // Toggle LED
#define CMD_RESET   'R'   // Reset processor

#define BUF_SIZE    255  // Max 255 for uint8_t length field

void handle_echo(void) {
    // Read length (1 byte, max 255)
    uint8_t len = uart_read_char();

    // Read data (len is uint8_t, so always <= 255)
    uint8_t buf[255];
    for (uint8_t i = 0; i < len; i++) {
        buf[i] = uart_read_char();
    }

    // Echo back
    for (uint8_t i = 0; i < len; i++) {
        uart_write_char(buf[i]);
    }

    // ACK
    uart_write_char('A');
}

void handle_ping(void) {
    uart_write_string("PONG");
    uart_write_char('A');
}

void handle_version(void) {
    uart_write_string("GRX930_ECHO_V1");
    uart_write_char('A');
}

void handle_led(void) {
    // Toggle LED
    static uint32_t led_state = 0;
    led_state ^= 1;
    uart_write_char('A');
}

void handle_reset(void) {
    uart_write_string("RESETTING...");
    // TODO: Trigger software reset via watchdog or CSR
    // For now, just loop forever
    while (1) {
        __asm__ volatile ("wfi");
    }
}

// ============================================================================
// Command Processor
// ============================================================================

void process_command(void) {
    uint8_t cmd = uart_read_char();

    switch (cmd) {
        case CMD_ECHO:
            handle_echo();
            break;

        case CMD_PING:
            handle_ping();
            break;

        case CMD_VERSION:
            handle_version();
            break;

        case CMD_LED:
            handle_led();
            break;

        case CMD_RESET:
            handle_reset();
            break;

        default:
            // Unknown command — respond with error
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

    // Announce boot
    uart_write_string("\r\n=== GRX930 UART Echo Test ===\r\n");
    uart_write_string("Ready. Waiting for commands...\r\n");

    // Main loop
    while (1) {
        if (uart_rx_available()) {
            process_command();
        }
    }
}