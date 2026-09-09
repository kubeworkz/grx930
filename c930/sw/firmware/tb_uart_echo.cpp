/**
 * GRX930 UART Echo Test — Verilator Simulation
 *
 * Simulates UART communication with the GRX930 firmware.
 * This is a simplified test that uses memory-mapped I/O to verify
 * the command processor logic without actual UART hardware.
 *
 * Build:
 *   make -C c930/sim
 *
 * Run:
 *   ./obj_dir/Vc930_soc4_verilator
 */

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include "Vc930_soc4_verilator.h"
#include "Vc930_soc4_verilator___024root.h"
#include "verilated.h"

// UART register offsets (must match firmware)
#define UART_TX_REG     0x00
#define UART_RX_REG     0x04
#define UART_STATUS_REG 0x08
#define UART_CTRL_REG   0x0C

// Status bits
#define UART_TX_READY   (1 << 0)
#define UART_RX_VALID   (1 << 1)

// Memory size
static const int MEM_BYTES = 65536;

// Simulated UART buffer
static uint8_t uart_tx_buf[1024];
static int uart_tx_idx = 0;
static uint8_t uart_rx_buf[1024];
static int uart_rx_idx = 0;
static int uart_rx_count = 0;

// DDR memory
static uint8_t ddr_mem[MEM_BYTES];

// Clock cycle counter
static uint64_t cycle = 0;

// ============================================================================
// Memory access functions
// ============================================================================

static uint8_t ddr_byte(Vc930_soc4_verilator *top, uint32_t addr) {
    if (addr < MEM_BYTES) {
        return ddr_mem[addr];
    }
    return 0;
}

static void ddr_write(Vc930_soc4_verilator *top, uint32_t addr, uint8_t data) {
    if (addr < MEM_BYTES) {
        ddr_mem[addr] = data;
    }
}

// ============================================================================
// UART simulation
// ============================================================================

static void uart_enqueue_rx(uint8_t byte) {
    if (uart_rx_count < 1024) {
        uart_rx_buf[uart_rx_count++] = byte;
    }
}

static uint8_t uart_dequeue_tx(void) {
    if (uart_tx_idx < uart_tx_buf[0]) {
        return uart_tx_buf[uart_tx_idx++];
    }
    return 0;
}

// ============================================================================
// Firmware loading (simplified — loads binary directly)
// ============================================================================

static void load_firmware(const char *filename) {
    FILE *f = fopen(filename, "rb");
    if (!f) {
        fprintf(stderr, "Error: cannot open firmware file: %s\n", filename);
        exit(1);
    }

    // Read binary into memory at firmware base address (0x80000000)
    // But our DDR model starts at 0, so we offset
    uint32_t firmware_base = 0x00000000;  // Adjust for DDR model
    size_t bytes_read = fread(&ddr_mem[firmware_base], 1, MEM_BYTES - firmware_base, f);
    fclose(f);

    printf("Loaded firmware: %s (%zu bytes)\n", filename, bytes_read);
}

// ============================================================================
// Test sequence
// ============================================================================

static void run_ping_test(Vc930_soc4_verilator *top) {
    printf("Test: Ping...\n");

    // Send ping command
    uart_enqueue_rx('P');

    // Run simulation until we get a response
    int timeout = 10000;
    while (uart_tx_idx == 0 && timeout > 0) {
        // Toggle clock
        top->i_clk = 0;
        top->eval();
        top->i_clk = 1;
        top->eval();
        cycle++;
        timeout--;
    }

    // Check response
    if (uart_tx_idx > 0) {
        printf("  Response: ");
        for (int i = 0; i < uart_tx_idx; i++) {
            printf("%c", uart_tx_buf[i]);
        }
        printf("\n");

        // Verify it's "PONG"
        if (uart_tx_idx == 4 && memcmp(uart_tx_buf, "PONG", 4) == 0) {
            printf("  PASS\n");
        } else {
            printf("  FAIL (expected PONG)\n");
        }
    } else {
        printf("  FAIL (no response)\n");
    }
}

static void run_echo_test(Vc930_soc4_verilator *top, const char *data) {
    printf("Test: Echo '%s'...\n", data);

    int len = strlen(data);

    // Send echo command + length + data
    uart_enqueue_rx('E');
    uart_enqueue_rx((uint8_t)len);
    for (int i = 0; i < len; i++) {
        uart_enqueue_rx(data[i]);
    }

    // Run simulation until we get a response
    int timeout = 10000;
    while (uart_tx_idx == 0 && timeout > 0) {
        top->i_clk = 0;
        top->eval();
        top->i_clk = 1;
        top->eval();
        cycle++;
        timeout--;
    }

    // Check response
    if (uart_tx_idx > 0) {
        printf("  Response: ");
        for (int i = 0; i < uart_tx_idx; i++) {
            printf("%c", uart_tx_buf[i]);
        }
        printf("\n");

        // Verify echo + ACK
        if (uart_tx_idx == len + 1 && memcmp(uart_tx_buf, data, len) == 0 && uart_tx_buf[len] == 'A') {
            printf("  PASS\n");
        } else {
            printf("  FAIL\n");
        }
    } else {
        printf("  FAIL (no response)\n");
    }
}

// ============================================================================
// Main
// ============================================================================

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    // Create top module
    Vc930_soc4_verilator *top = new Vc930_soc4_verilator;

    // Initialize
    top->i_clk = 0;
    top->i_rst_n = 0;
    top->eval();

    // Load firmware
    const char *firmware_file = "firmware_uart_echo_test.bin";
    if (argc > 1) {
        firmware_file = argv[1];
    }
    load_firmware(firmware_file);

    // Reset sequence
    printf("Resetting...\n");
    for (int i = 0; i < 10; i++) {
        top->i_clk = 0;
        top->eval();
        top->i_clk = 1;
        top->eval();
        cycle++;
    }
    top->i_rst_n = 1;

    // Run for a few cycles to let firmware start
    for (int i = 0; i < 100; i++) {
        top->i_clk = 0;
        top->eval();
        top->i_clk = 1;
        top->eval();
        cycle++;
    }

    // Run tests
    printf("\nRunning UART Echo Tests...\n");
    printf("========================\n\n");

    run_ping_test(top);
    run_echo_test(top, "Hello GRX930!");
    run_echo_test(top, "Test 123");

    printf("\n========================\n");
    printf("Total cycles: %lu\n", cycle);

    // Cleanup
    top->final();
    delete top;

    return 0;
}
