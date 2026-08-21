# C930 SoC -- Xilinx Artix-7 Port

This directory contains the Vivado project flow for synthesizing the C930 SoC
on a **Digilent Arty A7-35T** board (XC7A35TCSG324-1).

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

## Measured results (Vivado 2026.1 P&R, XC7A35TCSG324-1)

Routed with Vivado 2026.1 WebPACK (Basic license) on an 8 GB machine through
WSL (native-filesystem work copy, `-jobs 2`).

| Metric | Value |
|--------|-------|
| **Post-implementation Fmax** | **68.45 MHz** (WNS -4.609 ns @ 100 MHz) |
| Slice LUTs | 16,138 / 20,800 (77.6%) |
| Slice Registers (FFs) | 9,911 / 41,600 (23.8%) |
| Slices | 5,648 / 8,150 (69.3%) |
| DSP48E1 | 3 / 90 (3.3%) -- most multiplies mapped to LUTs |
| RAMB36E1 | 2 / 50 (4.0%) -- icache + dcache data arrays |
| Hold / Pulse-width | 0 failing endpoints |
| DRC | No errors (only REQP-1839 report limit note) |
| **Critical path** | `u_npu/u_core/m_reg_reg[1]_replica/C` -> `u_pe/o_ps_out_reg[29]/D` (NPU systolic MAC carry chain) |

**~1.94x over ECP5** (68.45 vs 35.31 MHz) -- the dedicated CARRY4 slices remove
~22 ns of routing from the 64-bit arithmetic paths. The remaining bottleneck is
the NPU PE accumulator carry chain, same as on ECP5. The design fits the
XC7A35T (77.6% LUTs); the A7-100T would give comfortable headroom.

The Yosys estimate (~21K LUTs) was pessimistic -- actual routed LUT count is
16.1K, which fits the -35T.

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
