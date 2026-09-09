# GRX930 RISC-V 64 Firmware

This firmware runs on the GRX930 RISC-V 64 processor and provides a command interface for the host Vortex runtime driver.

## Overview

The firmware implements a simple command processor that handles:
- Register reads/writes (DCR interface)
- Memory access (host ↔ device DMA)
- Kernel execution (load and run RISC-V ELF binaries)
- Profiling counters (PMU)

## Building

### Prerequisites

- RISC-V 64-bit toolchain (e.g., `riscv64-unknown-elf-gcc`)
- Make

### Build Commands

```bash
# Build firmware
make

# Generate disassembly for debugging
make disasm

# Print section sizes
make info

# Clean
make clean
```

## Files

| File | Description |
|------|-------------|
| `main.c` | Main firmware implementation (command processor) |
| `start.S` | RISC-V 64 startup assembly (stack setup, BSS clear, data copy) |
| `linker.ld` | Linker script defining memory regions |
| `Makefile` | Build system |

## Communication Protocol

The firmware communicates with the host via UART (or other transport):

### Host → Firmware Commands

| Command | Format | Description |
|---------|--------|-------------|
| `W` | `addr[4B] + value[4B]` | Register write |
| `R` | `addr[4B]` | Register read |
| `M` | `addr[4B] + len[4B] + data[len]` | Memory write |
| `N` | `addr[4B] + len[4B]` | Memory read |
| `G` | (none) | Go — start kernel |
| `H` | (none) | Halt — stop kernel |
| `S` | (none) | Status query |

### Firmware → Host Responses

| Response | Format | Description |
|----------|--------|-------------|
| ACK | `A` | Command acknowledged |
| Read data | `value[4B] + A` | Register/memory read response |
| Status | `status[4B] + A` | Kernel status (1=running, 0=done) |
| Error | `E` | Unknown command |

## Memory Map

| Region | Address | Size | Description |
|--------|---------|------|-------------|
| Firmware | `0x80000000` | 256 KB | Code + read-only data |
| RAM | `0x80040000` | 256 KB | Stack, heap, BSS |
| Kernel | `0x81000000` | 16 MB | User kernel load area |
| DRAM | `0x80000000` | 256 MB | Main memory (overlaps firmware) |

## Integration with Vortex Runtime

The firmware is designed to work with the `libvortex-rv64chip.so` backend driver:

```bash
# On host
VORTEX_DRIVER=rv64chip \
RV64CHIP_TRANSPORT=uart \
RV64CHIP_DEVICE=/dev/ttyUSB0 \
./sgemm_tcu_wg_dxa -m 64 -n 64 -k 16
```

## TODO

- [ ] Implement ELF loader (parse headers, load segments)
- [ ] Add TCU/DXA initialization
- [ ] Add interrupt handling
- [ ] Add multi-core support
- [ ] Add cache configuration
- [ ] Add memory protection (MMU/MPU)

## Customization

### UART Registers

Update the UART register definitions in `main.c` to match your hardware:

```c
#define UART_BASE           0x10000000ULL
#define UART_TX_REG         (*(volatile uint32_t*)(UART_BASE + 0x00))
#define UART_RX_REG         (*(volatile uint32_t*)(UART_BASE + 0x04))
#define UART_STATUS_REG     (*(volatile uint32_t*)(UART_BASE + 0x08))
```

### Memory Map

Update the memory map in `main.c` and `linker.ld` to match your chip's memory layout.

### Command Processor

The command processor in `main.c` is simplified. Replace the DCR register file with your actual command processor hardware interface.
