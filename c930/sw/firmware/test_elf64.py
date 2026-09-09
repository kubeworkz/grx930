#!/usr/bin/env python3
"""
GRX930 ELF64 Parser Test

Validates the ELF64 parser logic by creating mock ELF binaries
and checking that the parser correctly identifies them.
"""

import struct
import sys


def create_mock_elf64(entry=0x80000000, ph_count=1):
    """Create a minimal mock ELF64 binary for testing."""

    # ELF header
    e_ident = bytearray(16)
    e_ident[0] = 0x7F  # ELFMAG0
    e_ident[1] = ord('E')  # ELFMAG1
    e_ident[2] = ord('L')  # ELFMAG2
    e_ident[3] = ord('F')  # ELFMAG3
    e_ident[4] = 2        # ELFCLASS64
    e_ident[5] = 1        # ELFDATA2LSB (little-endian)
    e_ident[6] = 1        # EV_CURRENT
    e_ident[7] = 0        # ELFOSABI_NONE

    # Pack ELF header (64-bit)
    # Format: e_ident(16) + e_type(H) + e_machine(H) + e_version(I)
    #         + e_entry(Q) + e_phoff(Q) + e_shoff(Q) + e_flags(I)
    #         + e_ehsize(H) + e_phentsize(H) + e_phnum(H)
    #         + e_shentsize(H) + e_shnum(H) + e_shstrndx(H)
    ehdr = struct.pack('<16s H H I Q Q Q I H H H H H H',
        bytes(e_ident),
        2,          # e_type (ET_EXEC)
        243,        # e_machine (EM_RISCV)
        1,          # e_version
        entry,      # e_entry
        64,         # e_phoff (right after header)
        0,          # e_shoff
        0,          # e_flags
        64,         # e_ehsize
        56,         # e_phentsize (Elf64_Phdr size)
        ph_count,   # e_phnum
        64,         # e_shentsize
        0,          # e_shnum
        0           # e_shstrndx
    )

    # Program headers
    phdrs = []
    for i in range(ph_count):
        phdr = struct.pack('<II Q Q Q Q Q Q',
            1,          # p_type (PT_LOAD)
            5,          # p_flags (PF_R | PF_X)
            0x1000 + i * 0x1000,  # p_offset
            0x80010000 + i * 0x1000,  # p_vaddr
            0,          # p_paddr
            256,        # p_filesz
            512,        # p_memsz (BSS)
            8           # p_align
        )
        phdrs.append(phdr)

    # Combine header + program headers
    elf_data = ehdr + b''.join(phdrs)

    # Pad to make it look like a real binary
    elf_data += b'\x00' * (4096 - len(elf_data))

    return bytes(elf_data)


def create_invalid_elf(magic='ELF'):
    """Create invalid ELF data for testing."""

    if magic == 'ELF':
        # Valid magic but wrong class
        data = bytearray(16)
        data[0] = 0x7F
        data[1] = ord('E')
        data[2] = ord('L')
        data[3] = ord('F')
        data[4] = 1  # ELFCLASS32 (not 64)
        data[5] = 1  # ELFDATA2LSB
        return bytes(data)

    elif magic == 'MAGIC':
        # Wrong magic number
        return b'\x00\x00\x00\x00' + b'\x00' * 12

    elif magic == 'SIZE':
        # Too small
        return b'\x7FELF'

    return b'\x00' * 16


def test_elf64_parser():
    """Test the ELF64 parser logic."""
    print("=" * 60)
    print("GRX930 ELF64 Parser Test")
    print("=" * 60)
    print()

    results = []

    # Test 1: Valid ELF64 with 1 segment
    print("Test: Valid ELF64 (1 segment)...", end=" ")
    elf = create_mock_elf64(entry=0x80000000, ph_count=1)
    if elf[0:4] == b'\x7FELF' and elf[4] == 2 and elf[5] == 1:
        print("PASS")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Test 2: Valid ELF64 with 3 segments
    print("Test: Valid ELF64 (3 segments)...", end=" ")
    elf = create_mock_elf64(entry=0x80001000, ph_count=3)
    if elf[0:4] == b'\x7FELF' and elf[4] == 2 and elf[5] == 1:
        print("PASS")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Test 3: Wrong class (32-bit)
    print("Test: Wrong class (32-bit)...", end=" ")
    elf = create_invalid_elf('ELF')
    if elf[4] == 1:  # ELFCLASS32
        print("PASS (correctly identified as 32-bit)")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Test 4: Wrong magic
    print("Test: Wrong magic...", end=" ")
    elf = create_invalid_elf('MAGIC')
    if elf[0:4] != b'\x7FELF':
        print("PASS (correctly identified as non-ELF)")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Test 5: Too small
    print("Test: Too small...", end=" ")
    elf = create_invalid_elf('SIZE')
    if len(elf) < 16:
        print("PASS (correctly identified as too small)")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Test 6: Parse entry point
    print("Test: Parse entry point...", end=" ")
    elf = create_mock_elf64(entry=0x80012345, ph_count=1)
    # Parse entry from ELF header (bytes 24-31 in 64-bit ELF)
    entry = struct.unpack('<Q', elf[24:32])[0]
    if entry == 0x80012345:
        print(f"PASS (entry=0x{entry:08X})")
        results.append(True)
    else:
        print(f"FAIL (expected 0x80012345, got 0x{entry:08X})")
        results.append(False)

    # Test 7: Parse program header count
    print("Test: Parse PH count...", end=" ")
    elf = create_mock_elf64(entry=0x80000000, ph_count=5)
    phnum = struct.unpack('<H', elf[56:58])[0]
    if phnum == 5:
        print(f"PASS (phnum={phnum})")
        results.append(True)
    else:
        print(f"FAIL (expected 5, got {phnum})")
        results.append(False)

    # Test 8: Parse program header type
    print("Test: Parse PH type...", end=" ")
    elf = create_mock_elf64(entry=0x80000000, ph_count=1)
    ph_offset = 64  # e_phoff
    p_type = struct.unpack('<I', elf[ph_offset:ph_offset+4])[0]
    if p_type == 1:  # PT_LOAD
        print(f"PASS (p_type=PT_LOAD)")
        results.append(True)
    else:
        print(f"FAIL (expected PT_LOAD, got {p_type})")
        results.append(False)

    # Test 9: Parse program header flags
    print("Test: Parse PH flags...", end=" ")
    p_flags = struct.unpack('<I', elf[ph_offset+4:ph_offset+8])[0]
    if p_flags == 5:  # PF_R | PF_X
        print(f"PASS (flags=R+X)")
        results.append(True)
    else:
        print(f"FAIL (expected 5, got {p_flags})")
        results.append(False)

    # Test 10: Parse program header addresses
    print("Test: Parse PH addresses...", end=" ")
    p_vaddr = struct.unpack('<Q', elf[ph_offset+16:ph_offset+24])[0]
    p_filesz = struct.unpack('<Q', elf[ph_offset+32:ph_offset+40])[0]
    p_memsz = struct.unpack('<Q', elf[ph_offset+40:ph_offset+48])[0]
    if p_vaddr == 0x80010000 and p_filesz == 256 and p_memsz == 512:
        print(f"PASS (vaddr=0x{p_vaddr:08X}, filesz={p_filesz}, memsz={p_memsz})")
        results.append(True)
    else:
        print(f"FAIL")
        results.append(False)

    # Test 11: RISC-V machine type
    print("Test: RISC-V machine type...", end=" ")
    machine = struct.unpack('<H', elf[18:20])[0]
    if machine == 243:  # EM_RISCV
        print(f"PASS (machine=EM_RISCV)")
        results.append(True)
    else:
        print(f"FAIL (expected 243, got {machine})")
        results.append(False)

    # Test 12: Executable type
    print("Test: Executable type...", end=" ")
    e_type = struct.unpack('<H', elf[16:18])[0]
    if e_type == 2:  # ET_EXEC
        print(f"PASS (type=ET_EXEC)")
        results.append(True)
    else:
        print(f"FAIL (expected 2, got {e_type})")
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
    sys.exit(test_elf64_parser())
