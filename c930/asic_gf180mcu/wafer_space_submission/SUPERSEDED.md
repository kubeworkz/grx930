# ⚠️ SUPERSEDED — DO NOT SUBMIT

**Status: VOID** (2026-09-22)

The GDS files in this directory (`grx930_test_chip_final.gds`,
`grx930_test_chip_with_seal.gds`) must **not** be submitted to wafer.space.

## Why they are void

1. **Stale RTL.** They were synthesized from
   `build/grx930_test_chip_synth_final.v` (built Sep 19 21:51), which
   predates the SRAM arbiter / cache-fill fixes in `grx930_test_chip.sv`
   (Sep 21 22:27).
2. **Missing main memory.** In that pre-fix synthesis the SRAM read-line
   was undriven, so Yosys treated the entire 64 KB array as dead logic and
   optimized it away — only the done-handshake flops survived
   (`u_sram.o_rd_done`, `u_sram.rd_valid_p1`). The CPU could never receive
   cache-line data; the chip would not execute from memory.
3. **No CTS.** The flow used a no-CTS workaround (DRT-0073), so the clock
   is routed as an ordinary signal with uncontrolled skew.

## Replacement

A corrected design (fixed arbiter/fill logic, 8 KB SRAM to fit the 1×1 die)
is being taken through the full OpenLane2 flow **with CTS**. A new GDS will
replace these files once validated.
