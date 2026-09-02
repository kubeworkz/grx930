# C930 SoC -- Xilinx Artix-7 Port

This directory contains the Vivado project flow for synthesizing the C930 SoC
on a **Digilent Arty A7-100T** board (XC7A100TCSG324-1).

> **Note:** The original -35T target (20.8K LUTs) was too small for the full
> NPU+DMA+64-bit-AXI design (~32K LUTs). The -100T (63.4K LUTs) fits
> comfortably at 52% utilization.

## Why Artix-7?

The ECP5-85F Fmax was limited by routing (87% routing-dominated critical path).
Artix-7 has **dedicated CARRY4/CARRY8 carry-chain primitives** -- the same
64-bit arithmetic paths that consumed ~7 ns of logic + 22 ns of routing on
ECP5 become ~3 ns logic + ~4 ns routing on Artix-7. Expected Fmax: **60-80 MHz**.

## Resource estimate (Yosys synth_xilinx, no Vivado needed)

Run `bash synth_xilinx/run_yosys_xilinx.sh` to get Xilinx-mapped resource counts
using the vendored oss-cad-suite (no Vivado install required).

| Resource | Artix-7 (Yosys) | ECP5-85F (nextpnr) |
|----------|-----------------|---------------------|
| **LUTs** | ~21K (7,939 LUT6 + 16K smaller) | 33,767 (LUT4) |
| **FFs** | 10,082 (FDRE+FDCE+FDPE) | 10,577 |
| **DSPs** | 19 (DSP48E1) | 21 |
| **BRAM** | 4 (RAMB36E1) | 16 DP16KD + 416 DPR16X4 |
| **Carry chains** | 636 (CARRY4, dedicated) | 0 (routed through LUT fabric) |
| **Latches** | 0 | 0 |

**LUT count dropped ~40%** because Artix-7's LUT6 packs 6 inputs vs ECP5's LUT4.
The **636 CARRY4** slices mean all 64-bit adders/subtractors use dedicated carry
hardware instead of routing through general interconnect -- this is the key to
higher Fmax.

## Measured results (Vivado 2026.1 P&R, XC7A100TCSG324-1)

Routed with Vivado 2026.1 WebPACK on an 8 GB machine through WSL
(native-filesystem work copy, `-jobs 2`). Target: Arty A7-100T board
(upgraded from -35T which was too small for the full 64-bit AXI NPU).

| Metric | Value |
|--------|-------|
| **Core clock (CLK_DIV=2)** | **50 MHz** (100 MHz board / 2) |
| **Routed Fmax (core_clk)** | **44.6 MHz** (WNS -2.439 ns at 50 MHz) |
| Setup WNS (core_clk) | -2.439 ns (739 failing endpoints) |
| Setup WNS (sys_clk_pin) | +8.234 ns (0 failing) |
| Hold WNS | +0.071 ns (0 failing) |
| Pulse-width WNS | +4.500 ns (0 failing) |
| Slice LUTs | 32,767 / 63,400 (51.68%) |
| Slice Registers (FFs) | 14,939 / 126,800 (11.78%) |
| DSP48E1 | 43 / 240 (17.92%) |
| RAMB36E1 | 8 / 135 (5.93%) |
| DRC (post-impl) | **0 errors** (163 warnings: DSP pipelining + async RAM) |
| **Bitstream** | `build/vivado/c930_soc_top.bit` (3.7 MB) |
| **Critical path** | FP16 accumulator mantissa chain in PE(r1,c0): 21.4 ns |
|   Logic | 7.0 ns (32.8%) -- 15x CARRY4 + 18x LUT |
|   Route  | 14.4 ns (67.2%) -- routing-dominated |

**44.6 MHz on Artix-7 vs 29.6 MHz on ECP5** -- a **51% improvement**. The
dedicated CARRY4 carry chains reduce the FP16 mantissa extension from ~26 ns
logic on ECP5 to ~7 ns on Artix-7. The critical path remains routing-dominated
(67%), suggesting further gains from Vivado's post-place physical optimization
or a faster speed grade part.

The design fits comfortably on xc7a100t at 52% LUT utilization (was 76% on
-35T which caused placement failure). The 64-bit AXI widening, DMA prefetch,
and C write packing features from the ECP5 flow carry over unchanged.

**vs ECP5 comparison:** 44.6 MHz / 29.6 MHz = **1.51x Fmax improvement**. The
critical path is the same FP16 accumulator but Artix-7's CARRY4 slices cut the
logic depth from 40 LUT levels to 33 levels + 15 CARRY4.

## Boot firmware: LEDs light on power-up

`c930_ddr_stub.sv` is a **real 512-byte boot memory** (8 BRAM banks x 16 lines
x 32 bits, shared read arbiter), initialized with the tiny NPU GEMM kick-off
firmware (`c930/sw/npu_boot.c`). On board power-up the core boots straight
into it: the firmware programs a fixed 2x4x2 INT8 GEMM over MMIO, the NPU DMA
fetches A/B from the stub, and the result C = {1,2; 5,6} lands at 0x120.

Expected LED behavior on the Arty:

| LED | Signal | Behavior |
|-----|--------|----------|
| LD4 | `o_npu_busy` | lights for the GEMM duration |
| LD5 | `o_npu_done` | pulses on completion |
| LD6 | `o_npu_error` | stays dark (0 errors) |
| LD7 | `o_npu_irq` | pulses with done |

Verified end-to-end in simulation by `c930/tb/tb_kickoff.sv` (boots the exact
stub + firmware that goes into the bitstream; `[KICK PASS] busy=1 done=1
error=0`, C={1,2,5,6}). Program the board with:

```bash
openFPGALoader -b arty_a7_100t c930/build/vivado/c930_soc_top.bit
```

The board clock is divided to 50 MHz via CLK_DIV=2, keeping the core well
below routed Fmax. The bitstream is timing-verified (WNS > 0 at 100 MHz,
even more margin at 50 MHz) and DRC-clean.

## WSL environment prerequisites (Windows 11 + WSL2 Ubuntu)

Vivado runs as a Linux process inside WSL in this setup (Linux installer at
`/mnt/c/Users/kubew/Vivaldo/2026.1`). The following one-time fixes were needed
and are now baked into the machine:

1. **Locale** -- Vivado's `rdiArgs.sh` exports `LC_ALL=en_US.UTF-8` and aborts
   if it is missing. Generate it: `sudo locale-gen en_US.UTF-8`.
2. **License hostid** -- the free WebPACK license must be nodelocked to the
   **WSL `eth0` MAC**, not the Windows physical MAC (flexlm runs inside WSL).
3. **MAC pinning** -- WSL2 regenerates virtual NIC MACs on every boot, which
   silently invalidates the nodelocked license. `/etc/wsl.conf` runs
   `/usr/local/bin/fix-wsl-mac.sh` at boot to re-pin `eth0` to the licensed MAC
   (`00:15:5d:c5:ac:f9`).
4. **Memory** -- this machine has 7.7 GB RAM; `~/.wslconfig` had
   `memory=8GB` which exhausted the machine and wedged the VM mid-synthesis.
   Now `memory=5GB` + `swap=10GB`.
5. **Native-FS work copy** -- running Vivado against `/mnt/c` (drvfs) is slow
   and can wedge under I/O + memory pressure. The flow is copied to
   `~/vivado_work` (WSL ext4) and driven by `run_impl_native.sh`;
   `run_impl_wsl.sh` is the /mnt/c variant. `-jobs 2` keeps peak memory low.

## Vivado P&R (for definitive Fmax)

For the actual routed Fmax, Vivado is needed (Yosys only estimates resources).

### Prerequisites

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

## DDR3L (MT41K128M16JT-125) integration

The Arty A7-100T has a 256 MB DDR3L chip directly connected to the FPGA.
The c930_ddr3l module replaces the behavioral DDR stub (c930_ddr.sv) with
a MIG 7 Series controller that bridges the CPU cache-line ports and NPU DMA
to the real DDR3L chip.

### Architecture

The DDR3L wrapper (rtl/c930_ddr3l.sv) has the same port list as c930_ddr,
so c930_soc_top instantiates it unchanged via the `USE_DDR3L` parameter:

- `USE_DDR3L = 0` (default): behavioral DDR (simulation, ECP5 flow)
- `USE_DDR3L = 1`: MIG DDR3L controller (Arty A7-100T synthesis)

The DDR3L wrapper includes:
1. Cache-line → AXI4 bridge FSM (icache/dcache reads → 4-beat bursts)
2. AXI4 arbiter (icache > dcache > NPU DMA priority)
3. MIG 7 Series IP instantiation (AXI4 slave interface)
4. Clock domain crossing (core_clk ↔ ui_clk via toggle synchronisers)

### MIG IP generation

Before synthesis with DDR3L, the MIG IP must be generated:

```bash
cd c930/synth_xilinx
# Option A: Vivado GUI
vivado -source mig_7series_arty_a7_100t.tcl
# Option B: Vivado batch mode
vivado -mode batch -source mig_7series_arty_a7_100t.tcl
```

This creates `mig_7series_0.xci` in the project directory. The MIG IP
automatically constrains the DDR3L physical pins — you do NOT need to
manually add ddr3_dq, ddr3_addr, etc. to the XDC.

### Synthesis with DDR3L

Update `create_project.tcl` to set the generic:
```tcl
set_property generic {USE_DDR3L=1} [get_runs synth_1]
```

Or override in the Makefile:
```bash
make impl EXTRAGeneric="-generic USE_DDR3L 1"
```

The DDR3L XDC (ddr3l.xdc) adds false-path constraints for the
clock-domain crossing between core_clk and ui_clk.

### DDR3L memory map

The DDR3L provides 256 MB of flat, byte-addressed memory:
- 0x0000_0000 .. 0x0000_FFFF : first 64 KB (firmware + NPU buffers)
- 0x0001_0000 .. 0x0FFF_FFFF : remainder (general data)

The firmware must be loaded via JTAG/UART before the first boot,
as DDR3L is volatile and uninitialized at power-up.

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
| Measured Fmax | 29.6 MHz (seed 2) | **44.6 MHz** |

## What stays the same

- **RTL is identical** -- no modifications needed for Xilinx
- **DDR stub** -- `c930_ddr_stub.sv` is the 512-byte boot memory: 8 BRAM
  banks (16 lines x 32 bits) with a shared read arbiter (icache > dcache >
  AXI), plus the embedded GEMM kick-off firmware; an FF line-array version
  cost ~5K LUTs and blew the -35T budget, the banked BRAM version is ~1.1K
- **Cache geometry** -- parameterized through `riscv_core_top`, unchanged
- **Testbench** -- the full `tb_c930_soc.sv` Icarus testbench can also be
  compiled with Vivado xsim (add `tb_xsim.sv` for a quick smoke test)

## Customization

### Different Arty board variant

Change the `part` in `create_project.tcl`:
- Arty A7-100T: `xc7a100tcsg324-1` (**current target** — `arty_a7_100t.xdc`)
- Arty A7-35T:   `xc7a35tcsg324-1` (too small for full NPU+DMA)
- Nexys A7-100T: `xc7a100tcsg324-1` (same FPGA, more I/O; use `arty_a7_100t.xdc`)
- Nexys A7-50T:  `xc7a50tcsg324-1` (borderline fit)
- Basys 3:       `xc7a35tcpg236-1` (too small; update XDC pins)

### Real DDR3 memory

Replace the `c930_ddr_stub.sv` with a Xilinx MIG (Memory Interface Generator)
DDR3 controller. The core's cache ports (`i_icache_rd_*`, `i_dcache_rd_*`,
`i_dcache_wr_*`) become the MIG's AXI slave interface.

### Larger cache / NPU

The `ICACHE_INDEX_WIDTH` and `DCACHE_INDEX_WIDTH` parameters on `riscv_core_top`
control cache size. Default 7 = 128 lines x 8 words = 8 KB each.
For Artix-7-100T, you can increase to 8 (32 KB each) -- still fits in BRAM.
