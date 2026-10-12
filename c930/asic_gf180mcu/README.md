# GRX930 Test Chip — wafer.space GF180MCU

Stripped-down GRX930 test chip targeting the wafer.space GF180MCU shuttle.

## Design Summary

| Feature | Value |
|---------|-------|
| Process | GF180MCU 180nm |
| Slot | 1×1 (full) |
| Die size | 3.93mm × 5.12mm |
| Core area | 12.92 mm² |
| I/O pads | 56 default, up to 168 |
| Clock | 50 MHz |
| Supply | 5V |
| Quantity | 1,000 bare dies |

## What's Included

- **RV64IMAC core** — 5-stage in-order, compressed ISA, single core
- **2KB I-cache + 2KB D-cache** — Tiny BRAM-based caches
- **2KB on-chip SRAM** — Boot/data memory (replaces DDR; the RTL is
  `grx930_sram_64kb`, shrunk to 256 × 64-bit words by the Plan B work)
- **UART (16550)** — Debug output at 115200 baud
- **GPIO** — 4-bit heartbeat LED output
- **External interrupt** — Single interrupt input
- **Boot ROM** — *not instantiated* (see below)

> **The chip has no boot path as built.** `c930_bootrom.sv` and
> `bootrom_wrapper.sv` are in the tapeout tree but nothing instantiates them
> (`hierarchy -top grx930_test_chip` drops both as unused; the OL2 netlist for
> `slotcore_v1` contains one module and no ROM), `CORE_RESET_PC` is `0x0`, and
> `grx930_sram_64kb` has no initial contents — so in silicon the core fetches
> whatever the SRAM powers up with. `asic_gf180mcu/boot.hex` is a four-word NOP
> loop, so even wiring the ROM up would not demonstrate anything. `make sim`
> boots the chip by loading a program into the SRAM from the testbench instead,
> and `+NO_PRELOAD` shows what silicon does today: zero UART bytes, X in the
> SRAM, `RESULT: FAIL`.
>
> A shuttle part needs a real boot source (a ROM with a banner/self-test, or an
> SRAM load path). That is a netlist change and a re-synthesis, so it is called
> out here rather than done silently.

## What's Removed (vs. full c930_soc_top)

| Component | Full SoC | Test Chip | Savings |
|-----------|----------|-----------|---------|
| CPU cores | 4× RV64IMAC | 1× RV64IMAC | ~3× area |
| NPU | 2× (8×8 systolic) | None | ~300K gates |
| L2 cache | 64KB shared | None | ~50K gates |
| DDR controller | Yes | None (on-chip SRAM) | ~100K gates |
| AXI4 crossbar | 4×4 | Simple bus fabric | ~20K gates |
| APLIC | Yes | None | ~10K gates |
| Cache coherency | Yes | None | ~5K gates |

## Area Budget

| Component | Estimated Area |
|-----------|---------------|
| Logic (30K cells) | 2.2–3.8 mm² |
| SRAM (64KB, 128 macros) | 2.94 mm² |
| Routing overhead (30%) | 1.5–2.0 mm² |
| **Total** | **6.6–8.8 mm²** |
| **Available core** | **12.92 mm²** |
| **Margin** | **32–49%** |
| **Total** | **~4.3 mm²** |
| **Available core** | **4.46 mm²** |
| **Margin** | **~3%** |

## Memory Map

```
0x0000_0000 – 0x0000_07FF : 2KB SRAM (code, data, stack; higher addresses alias)
0x0001_0000 – 0x0001_00FF : Boot ROM — planned, NOT instantiated (see above)
0x4000_1000 – 0x4000_100F : UART (16550, AXI4-Lite)
```

## Building

```bash
cd c930/asic_gf180mcu

# Estimate gate count
make gates

# Synthesis
make synth

# Place & route
make pnr

# DRC + LVS
make signoff

# Prepare submission package
make submit
```

## Simulation

`make sim` boots the chip from RTL and fails if it does not boot:

```bash
cd c930/asic_gf180mcu
make sim                                  # RTL boot test, ~18 s
make sim SIM_CLK_FREQ=50000000            # at the part's real clock
make sim SIM_PLUSARGS=+NO_PRELOAD         # negative control: must fail
make sim_gate                             # same test on the netlist (needs the PDK cell models)
make fw                                   # rebuild ../sw/test_chip_boot.hex
```

- Testbench: [`../tb/tb_grx930_test_chip.sv`](../tb/tb_grx930_test_chip.sv). It
  preloads the 2 KB SRAM with `../sw/test_chip_boot.hex`, releases reset and
  checks that the UART sends `GRX930 OK\n` at the DUT's own divisor, that the
  firmware's store/load-back pair reads back `0x2A5A_1234` at SRAM `0x400`, that
  the completion marker `0x0000_C0DE` is at `0x408`, and that the heartbeat
  counter is advancing. `RESULT: PASS`/`RESULT: FAIL` plus a non-zero exit status,
  which the Makefile turns into a failed target.
- Firmware: [`../sw/test_chip_boot.S`](../sw/test_chip_boot.S) (272 bytes), built
  by [`../sw/build_test_chip_fw.sh`](../sw/build_test_chip_fw.sh) with a RISC-V
  toolchain; the checked-in hex is the current build. It is `-march=rv64ima` with
  `.option norvc`, so a failure is never a compressed-decoder question, and it
  polls `STATUS.tx_fifo_full` before every character so the run exercises MMIO
  reads interleaved with I-cache fills.
- The RTL is `openlane2_rtl/src` (the tapeout tree the OL2 flow reads), not
  `../rv64imac/RTL` — the two differ by the cache index/tag and MMIO read-hold
  fixes. **They also differ in chip top:** `make synth`/`make pnr` here still read
  the root `grx930_test_chip.sv` with `../rv64imac/RTL`, which is the width-5
  cache configuration, while the shuttle netlist is built from
  `openlane2_rtl/src` at width 4. Worth unifying.

## wafer.space Submission Checklist

### Prerequisites
- [ ] GF180MCU PDK installed (`export PDK_ROOT=/path/to/gf180mcu`)
- [ ] Yosys with GF180MCU support
- [ ] OpenROAD with GF180MCU tech files
- [ ] Magic with GF180MCU DRC rules
- [ ] Netgen for LVS

### Design Files
- [ ] `build/grx930_test_chip_routed.gds` — Final GDS
- [ ] `build/grx930_test_chip_routed.v` — Gate-level netlist
- [ ] `build/grx930_test_chip_routed.spef` — Parasitic extraction
- [ ] `pad_ring.cfg` — Pad ring configuration

### Verification
- [ ] DRC clean (zero violations)
- [ ] LVS clean (netlist matches layout)
- [ ] Timing clean (setup/hold met at 50 MHz)
- [ ] Area within budget (≤12.92 mm² core)

### Submission
- [ ] Purchase slot on Crowd Supply ($8,000 standard / $7,000 early bird)
- [ ] Upload GDS to wafer.space portal
- [ ] Include all required files
- [ ] Verify pad ring matches default (56 pads)
- [ ] Confirm seal ring is included in GDS

### Deadlines
- **Early bird**: 30 September 2026 (expired)
- **Purchase deadline**: 9 December 2026
- **GDS submission**: 16 December 2026
- **Parts ship**: Q2 2027

## Cost

| Item | Cost |
|------|------|
| 1×1 slot (standard) | $8,000 |
| 1×1 slot (early bird) | $7,000 |
| Chip-on-board packaging | $1,500 |
| Full undiced wafer | $2,000 |
| **Total (slot + COB)** | **$9,500** |

**Per-die cost**: $8.00 (standard) / $7.00 (early bird)

## Comparison with Full SoC

| Metric | Test Chip (GF180MCU) | Full SoC (SKY130 ChipIgnite) |
|--------|---------------------|------------------------------|
| Cost | $8,000 | $10,000–$30,000 |
| Process | 180nm | 130nm |
| Die area | 20.12 mm² | 12–30 mm² |
| Quantity | 1,000 dies | 100–1,000 dies |
| Features | CPU + UART only | Full SoC (4 CPU, 2 NPU) |
| Timeline | Q2 2027 | Q3 2027 |
| Risk | Low (simple design) | Medium (complex design) |

## Next Steps

1. **Synthesize** the test chip to verify area fits
2. **Run DRC/LVS** to ensure clean submission
3. **Purchase slot** on Crowd Supply before 9 December 2026
4. **Write test firmware** for UART and GPIO
5. **Submit GDS** to wafer.space by 16 December 2026

## References

- [wafer.space](https://wafer.space/) — Budget silicon manufacturing
- [GF180MCU PDK](https://github.com/google/gf180mcu-pdk) — Open-source PDK
- [LibreLane](https://github.com/iop-alliance-librelane) — ASIC flow tools
- [wafer.space Discord](https://discord.gg/wafer-space) — Community support
