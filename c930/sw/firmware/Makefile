# GRX930 RISC-V 64 Firmware Makefile
# Builds the command processor firmware for the GRX930 chip

# Toolchain (update to match your RISC-V 64 toolchain)
CROSS_COMPILE ?= riscv64-linux-gnu-
CC = $(CROSS_COMPILE)gcc
OBJCOPY = $(shell $(CC) -dumpmachine)-objcopy
OBJDUMP = $(shell $(CC) -dumpmachine)-objdump
SIZE = $(shell $(CC) -dumpmachine)-size

# Flags
TOOLCHAIN_DIR = $(shell $(CC) -print-file-name=include)

CFLAGS = -march=rv64imac -mabi=lp64 -O2 -Wall -Wextra \
         -ffreestanding -nostdlib -nostartfiles \
         -isystem $(TOOLCHAIN_DIR) \
         -ffunction-sections -fdata-sections \
         -I./include

LDFLAGS = -T linker.ld -nostdlib -nostartfiles -static \
          -Wl,--gc-sections

# Target firmware (default: command processor, alternatives: uart_echo_test)
TARGET ?= main

# Sources
SRCS = $(TARGET).c
ASM_SRCS = start.S
OBJS = $(SRCS:.c=.o) $(ASM_SRCS:.S=.o)

# Output
ELF = firmware_$(TARGET).elf
BIN = firmware_$(TARGET).bin
HEX = firmware_$(TARGET).hex

# Default target
all: $(ELF) $(BIN) $(HEX)
	$(SIZE) $(ELF)

# Compile C source
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Compile assembly
%.o: %.S
	$(CC) $(CFLAGS) -c $< -o $@

# Link
$(ELF): $(OBJS) linker.ld
	$(CC) $(LDFLAGS) $(OBJS) -o $@

# Generate binary
$(BIN): $(ELF)
	$(OBJCOPY) -O binary $< $@

# Generate hex (for loading via UART)
$(HEX): $(ELF)
	$(OBJCOPY) -O verilog $< $@

# Generate disassembly for debugging
disasm: $(ELF)
	$(OBJDUMP) -d $< > firmware_$(TARGET).dis

# Clean
clean:
	rm -f $(OBJS) $(ELF) $(BIN) $(HEX) firmware_*.dis firmware_*.elf firmware_*.bin firmware_*.hex

# Flash via UART (example — replace with your actual flash command)
flash: $(BIN)
	@echo "Flash command not implemented — update this target for your hardware"
	@echo "Example: python3 flash_tool.py --port /dev/ttyUSB0 --file $(BIN)"

# Run UART echo test (host side)
test-echo:
	@echo "Run: python3 test_uart_echo.py --port /dev/ttyUSB0"
	@echo "Or:  python3 test_uart_echo.py --port /dev/ttyUSB0 --interactive"

# Debug: print section sizes
info: $(ELF)
	$(SIZE) -A $(ELF)

.PHONY: all clean disasm flash info
