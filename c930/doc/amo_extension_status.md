# A Extension (Atomics) Status

## TL;DR

The A extension is **already fully implemented** in the vendored RV64IMAC core.
No RTL changes needed. The compiler is already configured with `-march=rv64ima`.

The `atomicAdd` abort is caused by the grxcp code performing AMOs on **MMIO
addresses** (NPU CSR space at 0x4000_0000+), not DDR addresses. The dcache's
MMIO path does not support AMO operations — only regular loads/stores.

## Hardware evidence

| Component | File | Status |
|-----------|------|--------|
| AMO ALU | `rv64imac/RTL/riscv_core_amo_alu.sv` | ✅ AMOSWAP, AMOADD, AMOAND, AMOOR, AMOXOR, AMOMIN, AMOMAX |
| LR/SC | `rv64imac/RTL/riscv_core_dcache_controller.sv` | ✅ AMO_OP state, reservation tracking |
| Decoder | `rv64imac/RTL/riscv_core_main_decoder.sv:184-197` | ✅ Opcode 7'b0101111 fully decoded |
| Pipeline | `rv64imac/RTL/riscv_core_top.sv` | ✅ AMO signals piped ID→EX→MEM (lines 715, 730, 1393, 1407) |
| Compiler | `c930/Makefile:67` | ✅ `-march=rv64ima` (includes A extension) |

## Known limitation: AMOs to MMIO

The dcache controller has separate paths for cached and uncached (MMIO) accesses.
The MMIO path (`MMIO_READ`/`MMIO_WRITE` states, line 266) only checks `i_read`
and `i_write` — it does **not** check `i_amo`.

When an AMO instruction targets an MMIO address (>= 0x4000_0000):
1. The MMIO path does NOT match (no `i_read` or `i_write` asserted)
2. The AMO falls through to the cached path
3. The cached path tries to access the MMIO address as if it were DDR
4. This causes incorrect behavior (silent data corruption or hang)

**This is by design** — AMOs to device registers are architecturally
undefined on most RISC-V implementations. AMOs are meant for DDR-resident
counters and flags.

## Workaround

Use regular loads/stores for MMIO (NPU CSR space):
```c
// CORRECT: regular store for NPU CSR
*(volatile u32 *)(MMIO_BASE + 0x00) = CSR_START;

// INCORRECT: AMO to MMIO (will fail)
amoadd.w rd, rs2, (MMIO_BASE + 0x00)
```

Use AMOs only for DDR-resident counters:
```c
// CORRECT: AMO to DDR-resident counter
volatile u32 *counter = (volatile u32 *)0x8000u;
amoadd.w rd, rs2, (counter)
```

## If grxcp needs AMOs to MMIO

The dcache controller needs a patch to add an AMO state in the MMIO path.
This would involve:
1. Adding `AMO_MMIO_READ` state in the dcache FSM
2. Reading the old value via the MMIO port
3. Computing the AMO result via the AMO ALU
4. Writing back via `MMIO_WRITE`
5. Returning the old value to the core

This is a ~50-line change to `riscv_core_dcache_controller.sv`.
