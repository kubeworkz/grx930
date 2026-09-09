/**
 * GRX930 RISC-V 64 Chip Firmware
 *
 * This firmware runs on the GRX930 RISC-V 64 processor and provides a
 * command interface for the host Vortex runtime driver. It handles:
 *   - Register reads/writes (Command Processor interface)
 *   - Memory access (host ↔ device DMA)
 *   - Kernel execution (load and run RISC-V ELF binaries)
 *   - Profiling counters (PMU)
 *
 * Communication protocol (UART example):
 *   Host → Firmware:
 *     'W' + addr[4B] + value[4B]  → Register write
 *     'R' + addr[4B]              → Register read
 *     'M' + addr[4B] + len[4B] + data[len]  → Memory write
 *     'N' + addr[4B] + len[4B]   → Memory read
 *     'G'                         → Go (start kernel)
 *     'H'                         → Halt (stop kernel)
 *     'S'                         → Status query
 *
 *   Firmware → Host:
 *     value[4B] + 'A'             → Read response + ACK
 *     'A'                         → Write ACK
 *     status[4B] + 'A'           → Status response
 */

#include <stdint.h>
#include <stddef.h>
#include "elf64.h"

/* Minimal string functions for freestanding */
static void* memcpy_f(void* dst, const void* src, size_t len) {
    uint8_t* d = (uint8_t*)dst;
    const uint8_t* s = (const uint8_t*)src;
    for (size_t i = 0; i < len; i++) {
        d[i] = s[i];
    }
    return dst;
}

/* Forward declarations from elf64_loader.c */
extern int elf64_load(const void *elf_data, size_t elf_size, uint64_t *entry_out);
extern void elf64_print_info(const void *elf_data, size_t elf_size);

// ============================================================================
// Hardware Register Map (must match VX_types.vh)
// ============================================================================

// Command Processor (CP) registers
#define CP_REG_START        0x4000  // Start pulse
#define CP_REG_MPM_CLASS    0x4004  // Profiling class
#define CP_REG_PMU_CMD      0x4008  // PMU command
#define CP_REG_PMU_VALUE    0x400C  // PMU value
#define CP_REG_DCR_BASE     0x4100  // DCR write base
#define CP_REG_CSR_BASE     0x4200  // CSR read base

// Memory map
#define DRAM_BASE           0x80000000ULL
#define DRAM_SIZE           0x10000000ULL  // 256 MB
#define MMIO_BASE           0xF0000000ULL

// ============================================================================
// UART Driver (replace with your actual UART hardware)
// ============================================================================

// TODO: Replace with your actual UART register addresses
#define UART_BASE           0x10000000ULL
#define UART_TX_REG         (*(volatile uint32_t*)(UART_BASE + 0x00))
#define UART_RX_REG         (*(volatile uint32_t*)(UART_BASE + 0x04))
#define UART_STATUS_REG     (*(volatile uint32_t*)(UART_BASE + 0x08))

#define UART_TX_READY       (1 << 0)
#define UART_RX_VALID       (1 << 1)

void uart_init(void) {
    // TODO: Configure baud rate, parity, etc.
}

uint8_t uart_read(void) {
    while (!(UART_STATUS_REG & UART_RX_VALID));
    return (uint8_t)(UART_RX_REG & 0xFF);
}

void uart_write(uint8_t c) {
    while (!(UART_STATUS_REG & UART_TX_READY));
    UART_TX_REG = c;
}

void uart_write_string(const char* str) {
    while (*str) {
        uart_write(*str++);
    }
}

void uart_write_bytes(const void* data, size_t len) {
    const uint8_t* src = (const uint8_t*)data;
    for (size_t i = 0; i < len; i++) {
        uart_write(src[i]);
    }
}

void uart_write_hex32(uint32_t val) {
    const char hex[] = "0123456789ABCDEF";
    uart_write(hex[(val >> 24) & 0x0F]);
    uart_write(hex[(val >> 20) & 0x0F]);
    uart_write(hex[(val >> 16) & 0x0F]);
    uart_write(hex[(val >> 12) & 0x0F]);
    uart_write(hex[(val >> 8) & 0x0F]);
    uart_write(hex[(val >> 4) & 0x0F]);
    uart_write(hex[val & 0x0F]);
}

void uart_write_hex64(uint64_t val) {
    uart_write_hex32((uint32_t)(val >> 32));
    uart_write_hex32((uint32_t)(val & 0xFFFFFFFF));
}

void uart_read_bytes(void* data, size_t len) {
    uint8_t* dst = (uint8_t*)data;
    for (size_t i = 0; i < len; i++) {
        dst[i] = uart_read();
    }
}

// Forward declarations
int main(void);
void uart_init(void);
uint8_t uart_read(void);
void uart_write(uint8_t c);
void uart_write_string(const char* str);
void uart_write_bytes(const void* data, size_t len);
void uart_write_hex32(uint32_t val);
void uart_write_hex64(uint64_t val);
void uart_read_bytes(void* data, size_t len);
void cp_reg_write(uint32_t addr, uint32_t value);
uint32_t cp_reg_read(uint32_t addr);
void mem_write(uint64_t addr, const void* data, size_t len);
void mem_read(uint64_t addr, void* data, size_t len);

// ============================================================================
// Command Processor Registers (simplified)
// ============================================================================

// DCR register file (simplified — real implementation would use actual CP)
static uint32_t dcr_regs[256] = {0};
static uint32_t pmu_class = 0;

// PMU counters (simplified)
static uint64_t pmu_counters[64] = {0};

void cp_reg_write(uint32_t addr, uint32_t value) {
    uint32_t reg = (addr - CP_REG_DCR_BASE) >> 2;

    switch (addr) {
        case CP_REG_START:
            // Start pulse — trigger kernel execution
            // TODO: Launch kernel on the core(s)
            break;

        case CP_REG_MPM_CLASS:
            pmu_class = value;
            break;

        case CP_REG_PMU_CMD:
            // PMU command
            break;

        case CP_REG_PMU_VALUE:
            // PMU value
            break;

        default:
            if (addr >= CP_REG_DCR_BASE && addr < CP_REG_CSR_BASE) {
                dcr_regs[reg] = value;
            }
            break;
    }
}

uint32_t cp_reg_read(uint32_t addr) {
    uint32_t reg = (addr - CP_REG_DCR_BASE) >> 2;

    switch (addr) {
        case CP_REG_START:
            return 0;  // Not busy

        case CP_REG_MPM_CLASS:
            return pmu_class;

        case CP_REG_PMU_VALUE:
            return (uint32_t)pmu_counters[pmu_class];

        default:
            if (addr >= CP_REG_DCR_BASE && addr < CP_REG_CSR_BASE) {
                return dcr_regs[reg];
            }
            return 0;
    }
}

// ============================================================================
// Memory Access
// ============================================================================

void mem_write(uint64_t addr, const void* data, size_t len) {
    // For unified memory, just copy
    memcpy_f((void*)addr, data, len);
}

void mem_read(uint64_t addr, void* data, size_t len) {
    memcpy_f(data, (const void*)addr, len);
}

// ============================================================================
// Kernel Execution (simplified)
// ============================================================================

// Function pointer to kernel entry point
typedef int (*kernel_entry_t)(void);

static kernel_entry_t kernel_entry = NULL;
static int kernel_running = 0;

/**
 * Load an ELF binary into memory and prepare for execution.
 * Uses the ELF64 parser to load segments to correct addresses.
 */
int load_kernel(uint64_t load_addr, const void* elf_data, size_t elf_size) {
    (void)load_addr;  // Not used — ELF loader places segments at their virtual addresses
    uint64_t entry;

    // Print ELF info for debugging
    elf64_print_info(elf_data, elf_size);

    // Load ELF binary using proper parser
    int result = elf64_load(elf_data, elf_size, &entry);

    if (result != 0) {
        // ELF load failed
        uart_write_string("ELF load failed: ");
        uart_write((uint8_t)('0' + (-result)));
        uart_write_string("\r\n");
        return -1;
    }

    // Set kernel entry point from ELF header
    kernel_entry = (kernel_entry_t)entry;

    uart_write_string("Kernel loaded at entry=0x");
    uart_write_hex64(entry);
    uart_write_string("\r\n");

    return 0;
}

/**
 * Start kernel execution.
 * This would typically:
 * 1. Set up stack pointer
 * 2. Configure MMU/TLB if needed
 * 3. Jump to kernel entry point
 */
int start_kernel(void) {
    if (!kernel_entry) return -1;

    kernel_running = 1;

    // TODO: Actual kernel launch
    // This might involve:
    // - Setting CSR registers (mstatus, mtvec, etc.)
    // - Configuring memory regions
    // - Jumping to kernel_entry()
    // - The kernel would then use TCU/DXA instructions

    // For now, call directly (simplified)
    int result = kernel_entry();
    kernel_running = 0;

    return result;
}

/**
 * Check if kernel is still running.
 */
int is_kernel_running(void) {
    return kernel_running;
}

// ============================================================================
// Main Command Loop
// ============================================================================

void process_command(void) {
    uint8_t cmd = uart_read();

    switch (cmd) {
        case 'W': {
            // Register write: addr[4B] + value[4B]
            uint32_t addr, value;
            uart_read_bytes(&addr, 4);
            uart_read_bytes(&value, 4);
            cp_reg_write(addr, value);
            uart_write('A');  // ACK
            break;
        }

        case 'R': {
            // Register read: addr[4B] → value[4B] + ACK
            uint32_t addr;
            uart_read_bytes(&addr, 4);
            uint32_t value = cp_reg_read(addr);
            uart_write_bytes(&value, 4);
            uart_write('A');
            break;
        }

        case 'M': {
            // Memory write: addr[4B] + len[4B] + data[len] → ACK
            uint32_t addr, len;
            uart_read_bytes(&addr, 4);
            uart_read_bytes(&len, 4);

            uint8_t buf[len];
            uart_read_bytes(buf, len);
            mem_write(addr, buf, len);
            uart_write('A');
            break;
        }

        case 'N': {
            // Memory read: addr[4B] + len[4B] → data[len] + ACK
            uint32_t addr, len;
            uart_read_bytes(&addr, 4);
            uart_read_bytes(&len, 4);

            uint8_t buf[len];
            mem_read(addr, buf, len);
            uart_write_bytes(buf, len);
            uart_write('A');
            break;
        }

        case 'G': {
            // Go: start kernel execution
            (void)start_kernel();
            // TODO: Return result or status
            uart_write('A');
            break;
        }

        case 'H': {
            // Halt: stop kernel execution
            kernel_running = 0;
            uart_write('A');
            break;
        }

        case 'S': {
            // Status: query kernel state
            uint32_t status = is_kernel_running() ? 1 : 0;
            uart_write_bytes(&status, 4);
            uart_write('A');
            break;
        }

        default:
            // Unknown command
            uart_write('E');  // Error
            break;
    }
}

// ============================================================================
// Startup C code (called from start.S)
// ============================================================================

// Linker symbols
extern uint32_t _bss_start;
extern uint32_t _bss_end;
extern uint32_t _data_start;
extern uint32_t _data_end;

void startup_c(void) {
    /* Clear BSS */
    uint32_t* bss = &_bss_start;
    uint32_t* bss_end = &_bss_end;
    while (bss < bss_end) {
        *bss++ = 0;
    }

    /* TODO: Copy initialized data from ROM to RAM if needed */
    /* For now, data is placed directly in RAM by the linker */

    /* Call main */
    main();
}

// ============================================================================
// Entry Point
// ============================================================================

int main(void) {
    // Initialize hardware
    uart_init();

    // TODO: Initialize TCU, DXA, caches, etc.

    // Main loop: process commands from host
    while (1) {
        process_command();
    }

    return 0;
}
