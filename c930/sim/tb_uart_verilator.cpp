/**
 * GRX930 UART Test — Verilator Simulation
 *
 * Simulates the GRX930 SoC with UART communication.
 * Loads firmware into DDR, simulates UART TX/RX, and validates
 * the command processor logic.
 *
 * Build:
 *   cd c930/sim
 *   make -f Makefile.verilator
 *
 * Run:
 *   ./obj_dir/Vc930_uart_test [firmware.bin]
 */

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <queue>

// Verilator generated headers
#include "Vc930_soc4_verilator.h"
#include "Vc930_soc4_verilator___024root.h"
#include "verilated.h"

// ============================================================================
// Configuration
// ============================================================================

static const int MEM_SIZE = 65536;           // DDR model size (64 KB)
static const int UART_BASE = 0x40001000;     // UART register base
static const int UART_TX_DATA  = 0x00;
static const int UART_RX_DATA  = 0x04;
static const int UART_STATUS   = 0x08;
static const int UART_CTRL     = 0x0C;
static const int UART_IRQ_EN   = 0x10;

// ============================================================================
// Simulation State
// ============================================================================

static uint8_t ddr_mem[MEM_SIZE];
static uint64_t cycle = 0;

// UART simulation
static std::queue<uint8_t> uart_tx_queue;    // Data from firmware TX
static std::queue<uint8_t> uart_rx_queue;    // Data to firmware RX

// ============================================================================
// Memory Access (TB preload port)
// ============================================================================

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

static uint8_t read_byte(Vc930_soc4_verilator *top, uint32_t addr) {
    top->i_tb_rd_addr = addr;
    top->eval();
    return top->o_tb_rd_data;
}

// ============================================================================
// Firmware Loading
// ============================================================================

static void load_firmware(const char *filename) {
    FILE *f = fopen(filename, "rb");
    if (!f) {
        fprintf(stderr, "Error: cannot open firmware: %s\n", filename);
        exit(1);
    }

    // Read firmware into DDR model
    size_t bytes_read = fread(ddr_mem, 1, MEM_SIZE, f);
    fclose(f);

    printf("Loaded firmware: %s (%zu bytes)\n", filename, bytes_read);

    // Preload DDR through TB port
    for (size_t i = 0; i < bytes_read; i++) {
        preload_byte(top, i, ddr_mem[i]);
    }
}

// ============================================================================
// UART Simulation
// ============================================================================

/**
 * Simulate one clock cycle of UART TX.
 * Checks if firmware wrote to TX_DATA register and captures the byte.
 */
static void uart_tx_sim(Vc930_soc4_verilator *top) {
    // Read UART status register
    uint32_t status_addr = UART_BASE + UART_STATUS;
    uint8_t status = read_byte(top, status_addr);

    // Check if TX FIFO has data (bit 0 = TX full)
    // If not full, firmware might have written a byte
    // In real UART, we'd watch for write strobes, but here we poll
}

/**
 * Enqueue a byte for firmware to receive via UART RX.
 */
static void uart_enqueue_rx(uint8_t byte) {
    uart_rx_queue.push(byte);
}

/**
 * Dequeue a byte that firmware transmitted via UART TX.
 */
static uint8_t uart_dequeue_tx(void) {
    if (uart_tx_queue.empty()) {
        return 0;
    }
    uint8_t byte = uart_tx_queue.front();
    uart_tx_queue.pop();
    return byte;
}

/**
 * Process UART TX output pin.
 * When firmware asserts o_uart_txd, capture the byte.
 */
static void process_uart_output(Vc930_soc4_verilator *top) {
    static int tx_bit_cnt = 0;
    static uint8_t tx_byte = 0;
    static int tx_started = 0;

    uint8_t txd = top->o_uart_txd;

    if (!tx_started) {
        // Look for start bit (low)
        if (txd == 0) {
            tx_started = 1;
            tx_bit_cnt = 0;
            tx_byte = 0;
        }
    } else {
        // Collect data bits (8 bits, LSB first)
        if (tx_bit_cnt < 8) {
            tx_byte |= (txd << tx_bit_cnt);
            tx_bit_cnt++;
        } else if (tx_bit_cnt == 8) {
            // Stop bit (high)
            if (txd == 1) {
                // Complete byte received
                uart_tx_queue.push(tx_byte);
                printf("[UART TX] 0x%02X '%c'\n", tx_byte,
                       (tx_byte >= 32 && tx_byte < 127) ? tx_byte : '.');
            }
            tx_started = 0;
            tx_bit_cnt = 0;
        }
    }
}

// ============================================================================
// Clock and Reset
// ============================================================================

static void clock_tick(Vc930_soc4_verilator *top) {
    top->i_clk = 0;
    top->eval();
    top->i_clk = 1;
    top->eval();
    cycle++;
}

static void reset_sequence(Vc930_soc4_verilator *top) {
    printf("Resetting...\n");
    top->i_rst_n = 0;

    for (int i = 0; i < 20; i++) {
        clock_tick(top);
    }

    top->i_rst_n = 1;

    // Wait for firmware to start
    for (int i = 0; i < 1000; i++) {
        clock_tick(top);
        process_uart_output(top);
    }
}

// ============================================================================
// Test Commands
// ============================================================================

static void send_uart_byte(uint8_t byte) {
    uart_enqueue_rx(byte);
}

static void send_command(const char *cmd, const char *data = nullptr) {
    // Send command byte
    send_uart_byte(cmd[0]);

    if (data) {
        // Send length
        uint8_t len = strlen(data);
        send_uart_byte(len);

        // Send data
        for (int i = 0; i < len; i++) {
            send_uart_byte(data[i]);
        }
    }
}

// ============================================================================
// Main Test
// ============================================================================

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    // Create top module
    Vc930_soc4_verilator *top = new Vc930_soc4_verilator;

    // Initialize
    top->i_clk = 0;
    top->i_rst_n = 0;
    top->i_tb_wr_en = 0;
    top->i_tb_rd_addr = 0;
    top->i_uart_rxd = 1;  // UART idle high
    top->eval();

    // Load firmware
    const char *firmware_file = "firmware_uart_echo_test.bin";
    if (argc > 1) {
        firmware_file = argv[1];
    }

    load_firmware(firmware_file);

    // Reset and run
    reset_sequence(top);

    printf("\nRunning UART tests...\n");
    printf("====================\n\n");

    // Test 1: Ping
    printf("Test: Ping...\n");
    send_command("P");

    // Run simulation for a while, processing UART
    for (int i = 0; i < 50000; i++) {
        clock_tick(top);
        process_uart_output(top);

        // Check for response
        if (!uart_tx_queue.empty()) {
            // Read response
            std::string response;
            while (!uart_tx_queue.empty()) {
                uint8_t byte = uart_dequeue_tx();
                response += (char)byte;
            }

            printf("  Response: %s\n", response.c_str());

            if (response == "PONGA") {
                printf("  PASS\n");
            } else {
                printf("  FAIL (expected PONGA)\n");
            }
            break;
        }
    }

    // Test 2: Echo
    printf("\nTest: Echo 'Hello'...\n");
    send_command("E", "Hello");

    for (int i = 0; i < 50000; i++) {
        clock_tick(top);
        process_uart_output(top);

        if (!uart_tx_queue.empty()) {
            std::string response;
            while (!uart_tx_queue.empty()) {
                uint8_t byte = uart_dequeue_tx();
                response += (char)byte;
            }

            printf("  Response: %s\n", response.c_str());

            if (response == "HelloA") {
                printf("  PASS\n");
            } else {
                printf("  FAIL (expected HelloA)\n");
            }
            break;
        }
    }

    // Test 3: Version
    printf("\nTest: Version...\n");
    send_command("V");

    for (int i = 0; i < 50000; i++) {
        clock_tick(top);
        process_uart_output(top);

        if (!uart_tx_queue.empty()) {
            std::string response;
            while (!uart_tx_queue.empty()) {
                uint8_t byte = uart_dequeue_tx();
                response += (char)byte;
            }

            printf("  Response: %s\n", response.c_str());

            if (response == "GRX930_ECHO_V1A") {
                printf("  PASS\n");
            } else {
                printf("  FAIL (expected GRX930_ECHO_V1A)\n");
            }
            break;
        }
    }

    // Summary
    printf("\n====================\n");
    printf("Total cycles: %lu\n", cycle);
    printf("Simulation complete.\n");

    // Cleanup
    top->final();
    delete top;

    return 0;
}
