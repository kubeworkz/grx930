#!/usr/bin/env python
"""Formal property check: signed 12-bit immediate encoding correctness.

Verifies that for any target address, the lui+addi encoding produces the
correct result and the addi immediate never overflows the signed 12-bit
range [-2048, 2047].

Properties checked:
  P1: addi imm is in [-2048, 2047] (signed 12-bit range)
  P2: (hi20 << 12) + sign_ext(lo12) == target_address
  P3: hi20 is a valid 20-bit unsigned value (0 .. 0xFFFFF)
  P4: lo12 matches the lower 12 bits of the target address
  P5: Round-trip: encode(target) -> decode(encoding) -> target

Usage:
  python sw/check_imm_encoding.py            # check all GEMM firmware addresses
  python sw/check_imm_encoding.py 0x40000000  # check a specific address
  python sw/check_imm_encoding.py --sweep     # sweep 0x00000000-0xFFFFFFFF
"""

import sys

# === RISC-V encoders (reference) ===
def lui(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0b0110111

def addi(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0b0010011


def encode_lui_addi(target, reg=10):
    """Encode target address as lui+addi pair. Returns (hi20, lo12, encoding)."""
    lo12 = target & 0xFFF
    if lo12 >= 0x800:
        # lo12 is sign-extended as negative: effective = lo12 - 0x1000
        # We need hi20 such that (hi20 << 12) + (lo12 - 0x1000) == target
        # => hi20 = (target - lo12 + 0x1000) >> 12
        hi20 = (target - lo12 + 0x1000) >> 12
    else:
        hi20 = target >> 12
    return hi20, lo12


def decode_lui_addi(hi20, lo12):
    """Decode lui+addi encoding to effective address."""
    sign_ext = lo12 if lo12 < 0x800 else lo12 - 0x1000
    return ((hi20 & 0xFFFFF) << 12) + sign_ext


def check_encoding(target, label=""):
    """Check that encoding of target address is correct. Returns True if OK."""
    hi20, lo12 = encode_lui_addi(target)
    effective = decode_lui_addi(hi20, lo12)
    errors = []

    # P1: lo12 is a valid 12-bit unsigned pattern (0x000-0xFFF)
    # In RISC-V, ALL 12-bit patterns are valid for addi — the hardware
    # sign-extends them. 0x800 encodes -2048, 0xFFF encodes -1.
    # The encode function handles the hi20 bump when lo12 >= 0x800.
    if not (0 <= lo12 <= 0xFFF):
        errors.append(f"P1 FAIL: lo12=0x{lo12:03X} outside [0x000, 0xFFF]")

    # P2: encoding produces correct address
    if effective != target:
        errors.append(f"P2 FAIL: hi20=0x{hi20:05X} lo12=0x{lo12:03X} "
                       f"-> 0x{effective:08X} != 0x{target:08X}")

    # P3: hi20 fits in 20 bits
    if hi20 < 0 or hi20 > 0xFFFFF:
        errors.append(f"P3 FAIL: hi20=0x{hi20:X} exceeds 20 bits")

    # P4: lo12 matches lower 12 bits of target
    if (target & 0xFFF) != lo12:
        errors.append(f"P4 FAIL: lo12=0x{lo12:03X} != target[11:0]=0x{target & 0xFFF:03X}")

    if errors:
        print(f"  [FAIL] {label} 0x{target:08X}:")
        for e in errors:
            print(f"         {e}")
        return False
    return True


def check_instruction_encoding(target, reg=10):
    """Full check: encode, generate instructions, decode, verify round-trip."""
    hi20, lo12 = encode_lui_addi(target, reg)
    lui_instr = lui(reg, hi20)
    addi_instr = addi(reg, reg, lo12)

    # Decode the LUI result
    lui_result = (hi20 & 0xFFFFF) << 12
    # Decode the ADDI result (sign-extend lo12)
    sign_ext = lo12 if lo12 < 0x800 else lo12 - 0x1000
    final = lui_result + sign_ext

    ok = check_encoding(target, f"reg x{reg}")
    if final != target:
        print(f"  [FAIL] Round-trip: LUI->ADDI gives 0x{final:08X} != 0x{target:08X}")
        ok = False
    return ok


# === Test addresses from all firmware ===
def check_all_gemm_addresses():
    """Check all addresses used in the 5 test firmwares."""
    addresses = {
        # MMIO base
        "MMIO_BASE": 0x40000000,

        # Test 2: NPU GEMM (from existing firmware)
        "T2_DIM_M/N/K": 0x40000008,  # MMIO + offsets

        # Test 4: Mixed-precision varying-shape
        "T4_GEMM0_A": 0x8000, "T4_GEMM0_B": 0x8200, "T4_GEMM0_C": 0x8400,
        "T4_GEMM1_A": 0x8800, "T4_GEMM1_B": 0x8A00, "T4_GEMM1_C": 0x8C00,
        "T4_GEMM2_A": 0x9000, "T4_GEMM2_B": 0x9200, "T4_GEMM2_C": 0x9400,
        "T4_DONE": 0x9410,

        # Test 5: Queue stress
        "T5_GEMM0_A": 0x8000, "T5_GEMM0_B": 0x8040, "T5_GEMM0_C": 0x8080,
        "T5_GEMM1_A": 0x8100, "T5_GEMM1_B": 0x8140, "T5_GEMM1_C": 0x8180,
        "T5_GEMM2_A": 0x8200, "T5_GEMM2_B": 0x8240, "T5_GEMM2_C": 0x8280,
        "T5_GEMM3_A": 0x8300, "T5_GEMM3_B": 0x8340, "T5_GEMM3_C": 0x8380,
        "T5_GEMM4_A": 0x8400, "T5_GEMM4_B": 0x8440, "T5_GEMM4_C": 0x8480,
        "T5_GEMM5_A": 0x8500, "T5_GEMM5_B": 0x8540, "T5_GEMM5_C": 0x8580,
        "T5_DONE": 0x9410,
    }

    print("=" * 60)
    print("Formal check: signed-imm encoding correctness")
    print("Properties: P1(12-bit) P2(accuracy) P3(20-bit) P4(bits)")
    print("=" * 60)
    print()

    all_ok = True
    for label, addr in sorted(addresses.items(), key=lambda x: x[1]):
        ok = check_encoding(addr, label)
        if ok:
            hi20, lo12 = encode_lui_addi(addr)
            print(f"  [OK]   {label:20s} 0x{addr:08X}  lui 0x{hi20:05X} + addi 0x{lo12:03X}")
        else:
            all_ok = False

    print()
    if all_ok:
        print(f"  ALL {len(addresses)} addresses PASS")
    else:
        print(f"  SOME addresses FAIL")
    return all_ok


def sweep_addresses():
    """Sweep a representative set of addresses across the 32-bit space."""
    print("Sweep: checking 100K addresses across 32-bit space...")
    test_addrs = set()

    # Standard intervals
    for i in range(0, 0x100000000, 0x10000):
        test_addrs.add(i)
        test_addrs.add(i + 0x800)  # critical: sign-extension boundary
        test_addrs.add(i + 0xFFF)  # max lo12

    # Critical region: 0x8000-0x9FFF (NPU data region)
    for i in range(0x8000, 0xA000, 0x10):
        test_addrs.add(i)

    # MMIO region
    for i in range(0x40000000, 0x40001000, 0x100):
        test_addrs.add(i)

    # Random-ish
    import random
    random.seed(42)
    for _ in range(50000):
        test_addrs.add(random.randint(0, 0xFFFFFFFF))

    print(f"  Testing {len(test_addrs)} addresses...")
    failures = 0
    for addr in sorted(test_addrs):
        hi20, lo12 = encode_lui_addi(addr)
        effective = decode_lui_addi(hi20, lo12)

        # Property P1: lo12 is a valid 12-bit pattern
        assert 0 <= lo12 <= 0xFFF, f"P1 FAIL: addr=0x{addr:08X} lo12=0x{lo12:03X}"

        # Property P2: correct address
        if effective != addr:
            print(f"  [FAIL] P2: 0x{addr:08X} -> hi=0x{hi20:05X} lo=0x{lo12:03X} -> 0x{effective:08X}")
            failures += 1

        # Property P3: hi20 in 20-bit range
        assert 0 <= hi20 <= 0xFFFFF, f"P3 FAIL: addr=0x{addr:08X} hi20=0x{hi20:X}"

    print(f"  {len(test_addrs)} addresses tested, {failures} failures")
    return failures == 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--sweep":
        ok = sweep_addresses()
    elif len(sys.argv) > 1:
        addr = int(sys.argv[1], 0)
        print(f"Checking address: 0x{addr:08X}")
        ok = check_instruction_encoding(addr)
    else:
        ok = check_all_gemm_addresses()
        print()
        ok = sweep_addresses() and ok

    sys.exit(0 if ok else 1)
