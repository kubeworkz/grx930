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
// Hardware Register Map (must match your GRX930 UART)
// ============================================================================

// TODO: Replace with your actual UART base address
#define UART_BASE       0x10000000ULL

// UART registers (example — adjust offsets for your UART IP)
#define UART_TX_REG     (*(volatile uint32_t*)(UART_BASE + 0x00))
#define UART_RX_REG     (*(volatile uint32_t*)(UART_BASE + 0x04))
#define UART_STATUS_REG (*(volatile uint32_t*)(UART_BASE + 0x08))
#define UART_CTRL_REG   (*(volatile uint32_t*)(UART_BASE + 0x0C))
#define UART_BAUD_REG   (*(volatile uint32_t*)(UART_BASE + 0x10))

// Status register bits
#define UART_TX_READY   (1 << 0)  // TX FIFO not full
#define UART_RX_VALID   (1 << 1)  // RX FIFO not empty
#define UART_TX_EMPTY   (1 << 2)  // TX FIFO empty
#define UART_RX_OVERRUN (1 << 3)  // RX overrun error

// Control register bits
#define UART_TX_EN      (1 << 0)
#define UART_RX_EN      (1 << 1)
#define UART_TX_IRQ_EN  (1 << 2)
#define UART_RX_IRQ_EN  (1 << 3)

// LED (if available)
#define LED_BASE        0x20000000ULL
#define LED_REG         (*(volatile uint32_t*)(LED_BASE))

// ============================================================================
// UART Driver
// ============================================================================

void uart_init(uint32_t baud_div) {
    // Enable TX and RX
    UART_CTRL_REG = UART_TX_EN | UART_RX_EN;

    // Set baud rate divider
    UART_BAUD_REG = baud_div;

    // Wait for TX to be ready
    while (!(UART_STATUS_REG & UART_TX_READY));
}

void uart_write_char(uint8_t c) {
    // Wait for TX FIFO to have space
    while (!(UART_STATUS_REG & UART_TX_READY));
    UART_TX_REG = c;
}

uint8_t uart_read_char(void) {
    // Wait for RX data
    while (!(UART_STATUS_REG & UART_RX_VALID));
    return (uint8_t)(UART_RX_REG & 0xFF);
}

int uart_rx_available(void) {
    return (UART_STATUS_REG & UART_RX_VALID) != 0;
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
    LED_REG = led_state;
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

    // Initialize UART (115200 baud — adjust divider for your clock)
    // baud_div = clock_freq / (16 * baud_rate) - 1
    // For 50 MHz clock: 50000000 / (16 * 115200) - 1 = 26
    uart_init(26);

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
