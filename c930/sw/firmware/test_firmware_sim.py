#!/usr/bin/env python3
"""
GRX930 Firmware Simulation Test

Comprehensive simulation of the GRX930 firmware command processor.
Tests the full protocol flow including ELF loading and kernel execution.

Usage:
    python3 test_firmware_sim.py
"""

import struct
import sys


class GRX930Simulator:
    """Simulates the GRX930 firmware command processor."""

    def __init__(self):
        # Memory (simplified)
        self.memory = bytearray(1024 * 1024)  # 1 MB

        # DCR registers
        self.dcr_regs = [0] * 256

        # Kernel state
        self.kernel_entry = 0
        self.kernel_running = False

        # UART state
        self.rx_buffer = []
        self.tx_buffer = []

        # ELF loader state
        self.elf_loaded = False
        self.segments_loaded = 0

    def uart_write_char(self, c):
        """Write character to UART TX."""
        self.tx_buffer.append(c)

    def uart_read_char(self):
        """Read character from UART RX."""
        if self.rx_buffer:
            return self.rx_buffer.pop(0)
        return None

    def uart_rx_available(self):
        """Check if RX has data."""
        return len(self.rx_buffer) > 0

    def send_command(self, cmd, data=None):
        """Send a command to the firmware."""
        self.rx_buffer.append(cmd)
        if data is not None:
            if isinstance(data, str):
                data = list(data)
            elif isinstance(data, bytes):
                data = list(data)
            self.rx_buffer.append(len(data))
            self.rx_buffer.extend(data)

    def process_command(self):
        """Process one command from the RX buffer."""
        cmd = self.uart_read_char()
        if cmd is None:
            return False

        if cmd == 'P':  # Ping
            for c in "PONG":
                self.uart_write_char(c)
            self.uart_write_char('A')
            return True

        elif cmd == 'V':  # Version
            for c in "GRX930_ECHO_V1":
                self.uart_write_char(c)
            self.uart_write_char('A')
            return True

        elif cmd == 'E':  # Echo
            length = self.uart_read_char()
            if length is None:
                return False

            data = []
            for _ in range(length):
                byte = self.uart_read_char()
                if byte is None:
                    return False
                data.append(byte)

            for byte in data:
                self.uart_write_char(byte)
            self.uart_write_char('A')
            return True

        elif cmd == 'W':  # Register write
            addr = self._read_u32()
            value = self._read_u32()
            self._write_reg(addr, value)
            self.uart_write_char('A')
            return True

        elif cmd == 'R':  # Register read
            addr = self._read_u32()
            value = self._read_reg(addr)
            self._write_u32(value)
            self.uart_write_char('A')
            return True

        elif cmd == 'M':  # Memory write
            addr = self._read_u32()
            length = self._read_u32()

            for i in range(length):
                byte = self.uart_read_char()
                if byte is None:
                    return False
                self.memory[addr + i] = byte

            self.uart_write_char('A')
            return True

        elif cmd == 'N':  # Memory read
            addr = self._read_u32()
            length = self._read_u32()

            for i in range(length):
                self.uart_write_char(self.memory[addr + i])

            self.uart_write_char('A')
            return True

        elif cmd == 'G':  # Go (start kernel)
            if self.kernel_entry > 0:
                self.kernel_running = True
                # Simulate kernel execution
                self._simulate_kernel()
            self.uart_write_char('A')
            return True

        elif cmd == 'H':  # Halt
            self.kernel_running = False
            self.uart_write_char('A')
            return True

        elif cmd == 'S':  # Status
            status = 1 if self.kernel_running else 0
            self._write_u32(status)
            self.uart_write_char('A')
            return True

        elif cmd == 'L':  # Load ELF
            return self._handle_elf_load()

        else:  # Unknown command
            self.uart_write_char('E')
            return True

    def _handle_elf_load(self):
        """Handle ELF load command."""
        # Read ELF size
        elf_size = self._read_u32()

        # Read ELF data
        elf_data = bytearray()
        for i in range(elf_size):
            byte = self.uart_read_char()
            if byte is None:
                return False
            elf_data.append(byte)

        # Parse ELF header
        if len(elf_data) < 64:
            self.uart_write_char('E')  # Error
            return True

        # Check magic
        if elf_data[0:4] != b'\x7FELF':
            self.uart_write_char('E')
            return True

        # Check class (64-bit)
        if elf_data[4] != 2:
            self.uart_write_char('E')
            return True

        # Get entry point (bytes 24-31)
        entry = struct.unpack('<Q', elf_data[24:32])[0]
        self.kernel_entry = entry

        # Get program header offset and count
        phoff = struct.unpack('<Q', elf_data[32:40])[0]
        phnum = struct.unpack('<H', elf_data[56:58])[0]

        # Load segments
        self.segments_loaded = 0
        for i in range(phnum):
            offset = phoff + i * 56  # Elf64_Phdr size = 56 bytes
            p_type = struct.unpack('<I', elf_data[offset:offset+4])[0]

            if p_type == 1:  # PT_LOAD
                p_offset = struct.unpack('<Q', elf_data[offset+8:offset+16])[0]
                p_vaddr = struct.unpack('<Q', elf_data[offset+16:offset+24])[0]
                p_filesz = struct.unpack('<Q', elf_data[offset+32:offset+40])[0]
                p_memsz = struct.unpack('<Q', elf_data[offset+40:offset+48])[0]

                # Copy data to memory
                for j in range(p_filesz):
                    if p_vaddr + j < len(self.memory):
                        self.memory[p_vaddr + j] = elf_data[p_offset + j]

                # Zero BSS
                for j in range(p_filesz, p_memsz):
                    if p_vaddr + j < len(self.memory):
                        self.memory[p_vaddr + j] = 0

                self.segments_loaded += 1

        self.elf_loaded = True

        # Send success response
        self.uart_write_char('O')
        self.uart_write_char('K')
        self._write_u32(self.segments_loaded)
        self._write_u64(entry)
        self.uart_write_char('A')

        return True

    def _simulate_kernel(self):
        """Simulate kernel execution (simplified)."""
        # In real implementation, this would jump to kernel_entry
        # For simulation, just mark as done after some cycles
        pass

    def _read_u32(self):
        """Read 32-bit value from UART (little-endian)."""
        b0 = self.uart_read_char() or 0
        b1 = self.uart_read_char() or 0
        b2 = self.uart_read_char() or 0
        b3 = self.uart_read_char() or 0
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)

    def _write_u32(self, val):
        """Write 32-bit value to UART (little-endian)."""
        self.uart_write_char(val & 0xFF)
        self.uart_write_char((val >> 8) & 0xFF)
        self.uart_write_char((val >> 16) & 0xFF)
        self.uart_write_char((val >> 24) & 0xFF)

    def _write_u64(self, val):
        """Write 64-bit value to UART (little-endian)."""
        self._write_u32(val & 0xFFFFFFFF)
        self._write_u32((val >> 32) & 0xFFFFFFFF)

    def _read_reg(self, addr):
        """Read DCR register."""
        if addr < len(self.dcr_regs):
            return self.dcr_regs[addr]
        return 0

    def _write_reg(self, addr, value):
        """Write DCR register."""
        if addr < len(self.dcr_regs):
            self.dcr_regs[addr] = value


def create_mock_elf(entry=0x1000, segments=None):
    """Create a mock ELF64 binary for testing."""
    if segments is None:
        segments = [(0x1000, b'\x13\x00\x00\x00')]  # NOP instruction

    # ELF header
    e_ident = bytearray(16)
    e_ident[0] = 0x7F
    e_ident[1] = ord('E')
    e_ident[2] = ord('L')
    e_ident[3] = ord('F')
    e_ident[4] = 2  # 64-bit
    e_ident[5] = 1  # Little-endian

    ehdr = struct.pack('<16s H H I Q Q Q I H H H H H H',
        bytes(e_ident),
        2,          # ET_EXEC
        243,        # EM_RISCV
        1,          # version
        entry,      # entry
        64,         # phoff
        0,          # shoff
        0,          # flags
        64,         # ehsize
        56,         # phentsize
        len(segments),  # phnum
        64,         # shentsize
        0,          # shnum
        0           # shstrndx
    )

    # Program headers + data
    phdrs = bytearray()
    data = bytearray()

    for i, (vaddr, code) in enumerate(segments):
        offset = 64 + len(segments) * 56 + len(data)

        phdr = struct.pack('<II Q Q Q Q Q Q',
            1,          # PT_LOAD
            5,          # PF_R | PF_X
            offset,     # p_offset
            vaddr,      # p_vaddr
            0,          # p_paddr
            len(code),  # filesz
            len(code) + 64,  # memsz (with BSS)
            8           # align
        )
        phdrs.extend(phdr)
        data.extend(code)
        data.extend(b'\x00' * 64)  # BSS

    return bytes(ehdr + phdrs + data)


def run_test(name, sim, cmd, data=None, expected=None):
    """Run a single test case."""
    print(f"Test: {name}...", end=" ")

    sim.tx_buffer = []

    if data is not None:
        sim.send_command(cmd, data)
    else:
        sim.send_command(cmd)

    sim.process_command()

    response = ''.join(chr(b) if isinstance(b, int) else b for b in sim.tx_buffer)

    if expected is not None:
        if response == expected:
            print("PASS")
            return True
        else:
            print("FAIL")
            print(f"  Expected: {expected!r}")
            print(f"  Got:      {response!r}")
            return False
    else:
        print(f"Response: {response!r}")
        return True


def main():
    print("=" * 60)
    print("GRX930 Firmware Simulation Test")
    print("=" * 60)
    print()

    sim = GRX930Simulator()
    results = []

    # Test 1-5: Basic commands (same as echo test)
    results.append(run_test("Ping", sim, 'P', expected="PONGA"))
    results.append(run_test("Version", sim, 'V', expected="GRX930_ECHO_V1A"))
    results.append(run_test("Echo 'Hello'", sim, 'E', "Hello", expected="HelloA"))
    results.append(run_test("Echo empty", sim, 'E', "", expected="A"))
    results.append(run_test("Unknown cmd", sim, 'X', expected="EA"))

    # Test 6: Register write
    print("Test: Register write...", end=" ")
    sim.tx_buffer = []
    sim.rx_buffer.extend(['W'])
    sim.rx_buffer.extend([0x10, 0x00, 0x00, 0x00])  # addr = 0x10
    sim.rx_buffer.extend([0x42, 0x00, 0x00, 0x00])  # value = 0x42
    sim.process_command()
    response = ''.join(chr(b) if isinstance(b, int) else b for b in sim.tx_buffer)
    if response == "A" and sim.dcr_regs[0x10] == 0x42:
        print("PASS")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Test 7: Register read
    print("Test: Register read...", end=" ")
    sim.tx_buffer = []
    sim.rx_buffer.extend(['R'])
    sim.rx_buffer.extend([0x10, 0x00, 0x00, 0x00])  # addr = 0x10
    sim.process_command()
    response = ''.join(chr(b) if isinstance(b, int) else b for b in sim.tx_buffer)
    # Should be 4 bytes of value + 'A'
    if len(response) == 5 and response[4] == 'A':
        print("PASS")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Test 8: Memory write
    print("Test: Memory write...", end=" ")
    sim.tx_buffer = []
    sim.rx_buffer.extend(['M'])
    sim.rx_buffer.extend([0x00, 0x10, 0x00, 0x00])  # addr = 0x1000
    sim.rx_buffer.extend([0x04, 0x00, 0x00, 0x00])  # len = 4
    sim.rx_buffer.extend([0xDE, 0xAD, 0xBE, 0xEF])  # data
    sim.process_command()
    response = ''.join(chr(b) if isinstance(b, int) else b for b in sim.tx_buffer)
    if response == "A" and sim.memory[0x1000:0x1004] == b'\xDE\xAD\xBE\xEF':
        print("PASS")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Test 9: Memory read
    print("Test: Memory read...", end=" ")
    sim.tx_buffer = []
    sim.rx_buffer.extend(['N'])
    sim.rx_buffer.extend([0x00, 0x10, 0x00, 0x00])  # addr = 0x1000
    sim.rx_buffer.extend([0x04, 0x00, 0x00, 0x00])  # len = 4
    sim.process_command()
    response = ''.join(sim.tx_buffer)
    if response == "\xDE\xAD\xBE\xEFA":
        print("PASS")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Test 10: ELF load
    print("Test: ELF load...", end=" ")
    elf = create_mock_elf(entry=0x1000)
    sim.tx_buffer = []
    sim.rx_buffer.extend(['L'])
    sim.rx_buffer.extend([len(elf) & 0xFF, (len(elf) >> 8) & 0xFF,
                          (len(elf) >> 16) & 0xFF, (len(elf) >> 24) & 0xFF])
    sim.rx_buffer.extend(elf)
    sim.process_command()
    response = ''.join(sim.tx_buffer)
    if response.startswith("OK") and sim.elf_loaded:
        print("PASS")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Test 11: Kernel status
    print("Test: Kernel status...", end=" ")
    sim.tx_buffer = []
    sim.rx_buffer.extend(['S'])
    sim.process_command()
    response = ''.join(sim.tx_buffer)
    # Status should be 4 bytes + 'A'
    if len(response) == 5 and response[4] == 'A':
        print("PASS")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Test 12: Go (start kernel)
    print("Test: Go (start kernel)...", end=" ")
    sim.tx_buffer = []
    sim.kernel_entry = 0x1000
    sim.rx_buffer.extend(['G'])
    sim.process_command()
    response = ''.join(sim.tx_buffer)
    if response == "A" and sim.kernel_running:
        print("PASS")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Test 13: Halt
    print("Test: Halt...", end=" ")
    sim.tx_buffer = []
    sim.rx_buffer.extend(['H'])
    sim.process_command()
    response = ''.join(sim.tx_buffer)
    if response == "A" and not sim.kernel_running:
        print("PASS")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Summary
    print()
    print("=" * 60)
    passed = sum(results)
    total = len(results)
    print(f"Results: {passed}/{total} passed")

    if passed == total:
        print("ALL TESTS PASSED!")
    else:
        print(f"FAILURES: {total - passed}")

    print("=" * 60)

    return 0 if passed == total else 1


if __name__ == '__main__':
    sys.exit(main())
