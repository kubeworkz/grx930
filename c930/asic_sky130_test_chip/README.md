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
- **Size the die from the netlist** (`FP_SIZING: relative`, `FP_CORE_UTIL: 40`).
  The core area this produces is the number to compare against GF180, where the
  same netlist was 370,059 instances and 6.66 mm² of cell area.
- **Target 25 MHz** (`CLOCK_PERIOD: 40`), as the GF180 tapeout does, with
  `CLK_FREQ=25000000` and `BAUD_DIV=217` passed to the top so the UART runs at
  115,200 baud.
- **Synthesize module by module** (`SYNTH_HIERARCHY_MODE: deferred_flatten`),
  then flatten for place and route. Synthesized flat, ABC runs on the whole
  design at once, flip-flop memories and their multiplexer trees included, and is
  killed for memory on a 16 GB CI runner.
- **Keep lint on.** It reports no errors (153 warnings) and stops the flow on
  any new error. The GF180 runs skipped lint altogether.

## Measured so far

From the run with `CLOCK_PERIOD: 20` and `FP_CORE_UTIL: 45`, which stopped in
global routing:

| | SKY130 (`sky130_fd_sc_hd`) |
|---|---|
| Cells after synthesis | 147,558 |
| Cell area | 2.00 mm² (GF180: 6.66 mm²) |
| of which the 2 KB flip-flop SRAM | 1.06 mm² (53 %) |
| Die at 45 % utilization | 2.12 × 2.13 mm |
| Worst setup path | about 49 ns before repair, 30 ns after, ending in the EX stage (`alu_result_ex_mem`) |
| Hold fixing | 32,355 buffers, +13 % area |
| Global routing | 100 overflowing GCells (`GRT-0116`) |

50 MHz is out of reach without pipeline changes, so the clock is 25 MHz, and the
utilization is lowered to clear the routing overflow.

## Running it

CI runs it: [`.github/workflows/sky130-test-chip.yml`](../../.github/workflows/sky130-test-chip.yml).
Each run prints the area, timing, DRC and LVS results to the job log and the job
summary, and uploads the GDS, netlist and reports.

### On a self-hosted runner

Detailed routing takes longer than the 6 hours a GitHub-hosted job may run, so a
full run needs a self-hosted runner. The workflow uses one when the repository
variable `SKY130_RUNNER` holds its label; there the job may run for 48 hours.
Pull requests from forks always stay on a hosted runner, because this repository
is public and a self-hosted runner must not run code from outside it.

The machine needs:

- Linux x86-64, with Docker, and the runner's user allowed to use it;
- `jq`, for the job summary;
- 8 or more cores and 32 GB of memory (16 GB is enough for synthesis, routing is
  faster with more);
- about 50 GB of free disk: the LibreLane image, the SKY130 PDK (kept in the
  runner user's `~/.ciel` between runs) and a run directory.

To set it up:

1. Repository **Settings → Actions → Runners → New self-hosted runner**, and
   follow its commands on the machine. When `./config.sh` asks for extra labels,
   enter `sky130`. Install it as a service (`sudo ./svc.sh install && sudo ./svc.sh start`)
   so it survives a reboot.
2. **Settings → Secrets and variables → Actions → Variables → New repository
   variable**: name `SKY130_RUNNER`, value `sky130`.
3. **Actions → Sky130 test chip → Run workflow** on `main`.

Removing the variable sends every run back to hosted runners.

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
| Memories as SRAM macros instead of flip-flops | Yes: an OpenRAM SKY130 macro, or a DFFRAM-style compact array. The 2 KB SRAM alone is 53 % of the cell area. |
| High-density cells | `sky130_fd_sc_hd`, the densest SKY130 library, is already in use. |
| Placement density and routability | Yes: `FP_CORE_UTIL` / `PL_TARGET_DENSITY_PCT`, with OpenROAD's routability-driven placement. |
| Multibit flip-flops | No: SKY130's libraries have no multibit flops. |
| Track-height, single-fin, SDB/COAG and metal-pitch changes | No: those are set by the process and its cell library, not by the design. They are what a 28 nm or 12LP+ library brings. |
