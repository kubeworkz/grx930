# C930 SoC -- Xilinx Artix-7 Port

This directory contains the Vivado project flow for synthesizing the C930 SoC
on a **Digilent Arty A7-35T** board (XC7A35TCSG324-1).

## Why Artix-7?

The ECP5-85F Fmax was limited by routing (87% routing-dominated critical path).
Artix-7 has **dedicated CARRY4/CARRY8 carry-chain primitives** -- the same
64-bit arithmetic paths that consumed ~7 ns of logic + 22 ns of routing on
ECP5 become ~3 ns logic + ~4 ns routing on Artix-7. Expected Fmax: **60-80 MHz**.

## Prerequisites

- **Xilinx Vivado** (2023.2 or later; WebPACK edition is free for XC7A35T)
- `vivado` must be on PATH

```bash
# Source Vivado environment (adjust path to your install)
source /opt/Xilinx/Vivado/2023.2/settings64.sh
# or on Windows:
# C:\Xilinx\Vivado\2023.2\settings64.bat
```

## Quick start

```bash
cd c930/synth_xilinx

# Full flow (synth + impl + timing, ~15-30 min on 8-core):
make impl

# Or step by step:
make project    # ~30s  -- create Vivado project
make synth      # ~5min -- synthesis only (LUT/FF/DSP counts)
make impl       # ~20min -- full place + route + timing

# View reports:
make reports
```

## Output files

| File | Description |
|------|-------------|
| `build/vivado/post_synth_utilization.rpt` | Post-synthesis resource counts |
| `build/vivado/post_synth_timing.rpt` | Post-synthesis timing estimate |
| `build/vivado/post_impl_utilization.rpt` | Post-implementation resource counts |
| `build/vivado/post_impl_timing.rpt` | Post-implementation timing (definitive Fmax) |
| `build/vivado/post_impl_timing_paths.rpt` | Top 100 critical paths |

## Board connections

| Signal | Pin | Description |
|--------|-----|-------------|
| `i_clk` | E3 | 100 MHz oscillator |
| `i_rst_n` | N15 | Active-low reset button |
| `o_npu_busy` | H17 | LD4 -- NPU busy indicator |
| `o_npu_done` | K15 | LD5 -- NPU done indicator |
| `o_npu_error` | J13 | LD6 -- NPU error indicator |
| `o_npu_irq` | N14 | LD7 -- NPU IRQ indicator |

## What changes from the ECP5 flow

| Aspect | ECP5 (nextpnr) | Artix-7 (Vivado) |
|--------|----------------|-------------------|
| Carry chains | CCU2C (routed) | CARRY4/CARRY8 (dedicated) |
| Block RAM | DP16KD / DPR16X4 | RAMB36E1 / RAMB18E1 |
| DSP slices | TRELLIS_DSP | DSP48E1 |
| Constraints | `.lpf` | `.xdc` |
| Router | nextpnr (open-source) | Vivado (proprietary) |
| Expected Fmax | ~35 MHz | ~60-80 MHz |

## What stays the same

- **RTL is identical** -- no modifications needed for Xilinx
- **DDR stub** -- the same `c930_ddr_stub.sv` (tiny BRAM, 16 lines) works
- **Cache geometry** -- parameterized through `riscv_core_top`, unchanged
- **Testbench** -- the full `tb_c930_soc.sv` Icarus testbench can also be
  compiled with Vivado xsim (add `tb_xsim.sv` for a quick smoke test)

## Customization

### Different Arty board variant

Change the `part` in `create_project.tcl`:
- Arty A7-100T: `xc7a100tcsg324-1`
- Nexys A7-50T:  `xc7a50tcsg324-1`
- Basys 3:       `xc7a35tcpg236-1` (update XDC pins)

### Real DDR3 memory

Replace the `c930_ddr_stub.sv` with a Xilinx MIG (Memory Interface Generator)
DDR3 controller. The core's cache ports (`i_icache_rd_*`, `i_dcache_rd_*`,
`i_dcache_wr_*`) become the MIG's AXI slave interface.

### Larger cache / NPU

The `ICACHE_INDEX_WIDTH` and `DCACHE_INDEX_WIDTH` parameters on `riscv_core_top`
control cache size. Default 7 = 128 lines x 8 words = 8 KB each.
For Artix-7-100T, you can increase to 8 (32 KB each) -- still fits in BRAM.
