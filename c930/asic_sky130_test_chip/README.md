# GRX930 Test Chip on SKY130

The GRX930 test chip core (`grx930_test_chip`: one RV64IMAC core, 2 KB I-cache,
2 KB D-cache, 2 KB SRAM, 1 KB boot ROM, UART, GPIO) hardened on SkyWater SKY130
with the `sky130_fd_sc_hd` (high-density) standard cells.

It replaces the GF180MCU target in [`../asic_gf180mcu`](../asic_gf180mcu), whose
wafer.space shuttle was cancelled. The RTL is the same tapeout tree
([`../asic_gf180mcu/openlane2_rtl/src`](../asic_gf180mcu/openlane2_rtl/src)),
read in place: nothing in it is GF180-specific. It excludes the two unused ROM
modules, as the GF180 flow does.

## What this flow does

- **Harden the core on its own.** No pad ring yet: the pad frame, die size, I/O
  count and supply come from the SKY130 shuttle, and that is not chosen yet.
- **Size the die from the netlist** (`FP_SIZING: relative`, `FP_CORE_UTIL: 45`).
  The core area this produces is the number to compare against GF180, where the
  same netlist was 370,059 instances and 6.66 mm² of cell area.
- **Target 50 MHz** (`CLOCK_PERIOD: 20`), the RTL's default `CLK_FREQ`, so the
  UART baud divider matches the clock.
- **Synthesize module by module** (`SYNTH_HIERARCHY_MODE: deferred_flatten`),
  then flatten for place and route. Synthesized flat, ABC runs on the whole
  design at once, flip-flop memories and their multiplexer trees included, and is
  killed for memory on a 16 GB CI runner.
- **Keep lint on.** It reports no errors (153 warnings) and stops the flow on
  any new error. The GF180 runs skipped lint altogether.

## Running it

CI runs it: [`.github/workflows/sky130-test-chip.yml`](../../.github/workflows/sky130-test-chip.yml).
Each run prints the area, timing, DRC and LVS results to the job log and the job
summary, and uploads the GDS, netlist and reports.

To run it locally, use the same image. LibreLane fetches the SKY130 PDK
revision it pins into the mounted PDK directory:

```
docker run --rm -v "$PWD:/work" -v "$HOME/.ciel:/pdk" \
  -w /work/c930/asic_sky130_test_chip ghcr.io/librelane/librelane:3.0.17 \
  python3 -m librelane --pdk-root /pdk --pdk sky130A --scl sky130_fd_sc_hd \
    --flow classic --run-tag local config.json
```

Run it from the repository root; the config reads the RTL through a relative path.

## Where the area goes, and what can shrink it

The storage is flip-flops. The GF180 notes put a 64 KB flip-flop SRAM at about
34 mm² on its own, which is why the SRAM was cut to 2 KB. The two 2 KB caches are
flip-flop arrays too.

| Lever | Available on SKY130 with open tools |
|---|---|
| Memories as SRAM macros instead of flip-flops | Yes: an OpenRAM SKY130 macro, or a DFFRAM-style compact array. Likely the largest saving. |
| High-density cells | `sky130_fd_sc_hd`, the densest SKY130 library, is already in use. |
| Placement density and routability | Yes: `FP_CORE_UTIL` / `PL_TARGET_DENSITY_PCT`, with OpenROAD's routability-driven placement. |
| Multibit flip-flops | No: SKY130's libraries have no multibit flops. |
| Track-height, single-fin, SDB/COAG and metal-pitch changes | No: those are set by the process and its cell library, not by the design. They are what a 28 nm or 12LP+ library brings. |
