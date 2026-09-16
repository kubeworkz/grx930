# GRX930 — RISC-V AI SoC

A fully verified, FPGA-synthesizable RISC-V SoC with an integrated neural processing unit (NPU), multi-core CPU subsystem, L2 cache coherence, and AXI4 bus fabric. Targets the Nexys Video board (xc7a200tfbg484-1) and is designed as a stepping stone toward a production ASIC.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         GRX930 SoC                                  │
│                                                                     │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐       │
│  │  CPU 0   │   │  CPU 1   │   │  CPU 2   │   │  CPU 3   │       │
│  │ RV64IMAC │   │ RV64IMAC │   │ RV64IMAC │   │ RV64IMAC │       │
│  │ I/D Cache│   │ I/D Cache│   │ I/D Cache│   │ I/D Cache│       │
│  └────┬─────┘   └────┬─────┘   └────┬─────┘   └────┬─────┘       │
│       │              │              │              │               │
│  ┌────▼──────────────▼──────────────▼──────────────▼────┐         │
│  │              AXI4 Crossbar (4-master)                 │         │
│  └──┬─────────────┬──────────────┬───────────────┬──────┘         │
│     │             │              │               │                 │
│  ┌──▼───┐   ┌─────▼─────┐  ┌────▼────┐   ┌──────▼──────┐        │
│  │ L2   │   │  NPU 0    │  │  NPU 1  │   │  Peripherals│        │
│  │Cache │   │ 8×8 GEMM  │  │ 8×8 GEMM│   │  UART       │        │
│  │4-way │   │ INT8/FP16 │  │ INT8/FP16│  │  APLIC      │        │
│  └──┬───┘   └───────────┘  └─────────┘   │  Boot ROM   │        │
│     │                                      │  DMA Arb    │        │
│  ┌──▼──────────────────────────────────────▼──────────┐  │        │
│  │              DDR Stub / DDR3L Controller            │  │        │
│  │              64 KB BRAM (FPGA) / Real DRAM          │  │        │
│  └────────────────────────────────────────────────────┘  │        │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Specifications

| Feature | Details |
|---------|---------|
| **CPU** | 4× RV64IMAC, 5-stage in-order pipeline, AMO/LR/SC, I/D caches (256-bit lines) |
| **NPU** | 2× 8×8 systolic array, INT8/INT16/FP16/BF16 GEMM, pipelined normalize |
| **L2 Cache** | 4-way set-associative, 32–512 configurable sets, write-back, coherence invalidation |
| **Bus Fabric** | 4-master AXI4 crossbar, 64-bit data bus, 4-bit ID |
| **DMA Arbiter** | 4-master store-and-forward B-skid, combinational-loop-free |
| **Peripherals** | UART (115200 8N1), APLIC interrupt controller, 1 KB boot ROM |
| **Memory** | 64 KB BRAM stub (FPGA) or DDR3L MIG (real hardware) |
| **Target FPGA** | xc7a200tfbg484-1 (Nexys Video), 100 MHz sys_clk → 50 MHz core clock |
| **Fmax** | ~121 MHz post-implementation (WNS +7.883 ns) |
| **Utilization** | 125,735 LUTs (93.97%), 67,007 FFs (25.04%), 55 BRAM, 227 DSP |

## Project Structure

```
grx930/
├── c930/
│   ├── rtl/                    # SoC RTL (29 SystemVerilog modules)
│   │   ├── c930_soc_top.sv    # Top-level SoC
│   │   ├── c930_npu_top.sv    # NPU wrapper (2 instances)
│   │   ├── c930_npu_core.sv   # NPU datapath + control FSM
│   │   ├── c930_systolic_array.sv
│   │   ├── c930_tensor_pe.sv  # Processing element (FP32 normalize pipelined)
│   │   ├── c930_fp16_acc.sv   # FP16/BF16 accumulator (CLA-based)
│   │   ├── c930_fp_mul.sv     # FP16 multiplier
│   │   ├── c930_npu_act.sv    # Activation unit (sigmoid/tanh via LUT)
│   │   ├── c930_npu_dma.sv    # NPU AXI4 DMA master
│   │   ├── c930_npu_csr.sv    # NPU AXI4-Lite CSR slave
│   │   ├── c930_axi_crossbar.sv  # 4-master AXI4 interconnect
│   │   ├── c930_axi_dma_arb.sv   # DMA arbiter (B-skid for timing closure)
│   │   ├── c930_axi_cache_adapter.sv
│   │   ├── c930_l2.sv         # L2 cache (4-way, configurable sets)
│   │   ├── c930_uart.sv       # UART 115200 8N1
│   │   ├── c930_aplic.sv      # APLIC interrupt controller
│   │   ├── c930_bootrom.sv    # Boot ROM (firmware hex preload)
│   │   ├── c930_mmio_bridge.sv # CPU MMIO ↔ AXI4-Lite
│   │   ├── c930_mmio_arb.sv   # MMIO arbiter
│   │   ├── c930_ddr.sv        # BRAM DDR stub (64 KB)
│   │   └── c930_ddr3l.sv      # DDR3L MIG wrapper
│   ├── rv64imac/RTL/           # RISC-V CPU (38 modules)
│   │   ├── riscv_core_top.sv   # CPU top (5-stage RV64IMAC)
│   │   ├── riscv_core_hazard_unit.sv  # Forwarding + hazard detection (re-timed)
│   │   ├── riscv_core_csr_unit.sv     # CSR registers (mstatus, mtvec, etc.)
│   │   ├── riscv_core_icache_*.sv     # I-cache (controller + memory)
│   │   ├── riscv_core_dcache_*.sv     # D-cache (controller + memory)
│   │   └── ...
│   ├── tb/                     # Testbenches (52 files)
│   │   ├── tb_c930_soc.sv     # Full SoC with firmware
│   │   ├── tb_c930_soc_full.sv # Full SoC with DDR
│   │   ├── tb_arb_bskid_equiv.sv  # Arbiter equivalence (1200+ txns)
│   │   ├── tb_hazard_equiv.sv     # Hazard unit equivalence (300K cycles)
│   │   └── ...
│   ├── sw/                     # Firmware source + hex files
│   │   ├── c930_npu_driver.c  # NPU register-level driver
│   │   ├── boot.hex           # Boot ROM initialization
│   │   └── ...
│   ├── sim/                    # Verilator models
│   ├── doc/                    # Design notes & architecture docs
│   ├── synth_xilinx/           # Vivado synthesis flow
│   │   ├── create_project.tcl  # Project creation (xc7a200t)
│   │   ├── run_synth.tcl       # Synth + impl + timing reports
│   │   ├── xc7a200t_nexys_video.xdc  # Nexys Video pin constraints
│   │   ├── heal_mac.sh         # License MAC fix for WSL
│   │   ├── export_schematics.tcl     # Gate-level netlist export
│   │   ├── quick_export.tcl          # Per-subsystem batch export
│   │   └── export_schematic_pdfs.tcl # GUI schematic helper
│   ├── build/                  # Build artifacts (gitignored)
│   └── Makefile                # Simulation targets
├── rv64imac/                   # CPU core (submodule/directory)
└── README.md
```

## Getting Started

### Prerequisites

- **Icarus Verilog** (`iverilog` + `vvp`) — for simulation
- **Vivado 2026.1** — for FPGA synthesis (Nexys Video)
- **RISC-V toolchain** (`riscv64-unknown-elf-gcc`) — for firmware builds
- **Python 3** — for utility scripts

### Quick Simulation

```bash
cd c930

# Run the full SoC test suite (11 firmware tests, ~5-10 min)
make soc

# Run NPU integer GEMM tests (all matrix sizes)
make npu

# Run NPU FP16/BF16 GEMM tests
make npu_float

# Run arbiter equivalence gate (1200+ strict + random transactions)
make arb_equiv

# Run hazard unit equivalence gate (300K cycles)
make hazard_equiv
```

### Available Simulation Targets

| Target | Description | Duration |
|--------|-------------|----------|
| `make npu` | NPU integer GEMM (all matrix sizes) | ~1 min |
| `make npu_float` | NPU FP16/BF16 GEMM | ~2 min |
| `make npu_feed` | NPU feed/measurement pipeline | ~2 min |
| `make hazard` | CPU hazard unit (CSR flush, stalls) | ~30 sec |
| `make hazard_equiv` | Hazard unit equivalence (300K cycles) | ~5 min |
| `make arb_equiv` | DMA arbiter B-skid equivalence (1200+ txns) | ~3 min |
| `make soc` | Full SoC with firmware (11 tests) | ~10 min |
| `make soc_full` | Full SoC with DDR, all peripherals | ~15 min |
| `make quad` | Quad-core coherency | ~10 min |
| `make l2_coherent` | L2 cache coherence | ~10 min |

### FPGA Build

```bash
cd c930

# Launch full Vivado flow (synth + impl + timing reports)
make vivado_synth

# Or via the retry driver (auto-heals MAC, relaunches on failure)
powershell -File build/run_schematic_export.cmd
```

The flow targets **xc7a200tfbg484-1** (Nexys Video) with:
- 100 MHz board clock → 50 MHz core clock (CLK_DIV=2)
- UART TX/RX on FTDI pins
- 8 status LEDs (NPU0 busy/done/error/irq + NPU1 busy/done/error/irq)
- Quad-SPI bitstream generation (6.1 MB .bit + 6.1 MB .bin)

### Programming the FPGA

1. **JTAG (volatile):** Open Vivado → Hardware Manager → Program Device → `c930_soc_top.bit`
2. **Quad-SPI flash (persistent):** Add Configuration Memory Device → Program `c930_soc_top.bin`

## CPU Core (RV64IMAC)

The RISC-V core is a 5-stage in-order pipeline with:

- **Integer multiplication/division** — Booth multiplier, non-restoring divider
- **I-Cache** — 4 KB direct-mapped, 256-bit cache lines, AXI4 burst read
- **D-Cache** — 4 KB direct-mapped, write-back with byte strobes
- **AMO/LR/SC** — Full atomic memory operation support
- **Hazard unit** — 3-stage forwarding, stall-on-use for loads, CSR flush on exceptions
- **MMIO port** — AXI4-Lite bridge for uncached peripheral access

### CPU Parameters

```systemverilog
parameter int ICACHE_INDEX_WIDTH = 7   // 128-entry I-cache
parameter int DCACHE_INDEX_WIDTH = 7   // 128-entry D-cache
parameter logic [63:0] CORE_RESET_PC = 64'h0  // Boot vector
```

## NPU Architecture

The NPU is a parameterized systolic array GEMM engine:

- **Systolic array:** 8×8 PEs (configurable via `NUM_ROWS`/`NUM_COLS`)
- **Data types:** INT8, INT16, FP16, BF16 (selectable per GEMM)
- **Accumulator:** 48-bit fixed-point or FP16 with CLA-based adder
- **Normalize stage:** Pipelined FP32 → FP16 conversion (1 extra cycle latency)
- **Activation unit:** Sigmoid/tanh via piecewise-linear LUT
- **DMA:** AXI4 full master, burst reads/writes for A/B/C matrices
- **CSR interface:** AXI4-Lite slave, command queue (depth 4), cross-GEMM prefetch
- **Dual instance:** NPU0 + NPU1 (ENABLE_NPU1 generic)

### NPU Parameters

```systemverilog
parameter int NUM_ROWS = 8   // Systolic rows (reduction elements)
parameter int NUM_COLS = 8   // Systolic cols (output elements)
parameter int DIN_W    = 8   // Activation/weight width
parameter int ACC_W    = 48  // Accumulator width
parameter int MAX_M    = 64  // Max output rows
parameter int MAX_K    = 256 // Max reduction length
parameter int MAX_N    = 8   // Max output cols
```

## L2 Cache

4-way set-associative write-back cache with:

- **Configurable sets:** 32–512 (32 sets for FPGA fit, 512 for simulation)
- **Coherence:** Invalidation-based protocol with 8 L1 invalidation ports
- **Write log:** Depth-8 FIFO for write-back scheduling
- **AXI4 slave ports:** Separate read/write channels for concurrent CPU + NPU access

## Timing Closure

The design achieved full timing closure on xc7a200tfbg484-1 through a systematic retiming campaign:

| Milestone | WNS (ns) | Fmax (MHz) | Technique |
|-----------|----------|------------|-----------|
| Initial | −20.7 | 0 | — |
| BUFG clock distribution | −4.0 | 0 | BUFG on core clock |
| Accumulator retiming | −1.5 | 45 | Pipeline FP16 normalize stage |
| Hazard unit retime | −0.76 | 48 | Shadow forwarding + registered selects |
| B-skid (wr_owner fanout) | +7.9 | 121 | Store-and-forward B response |
| **Final** | **+7.883** | **~121** | All paths MET |

Post-implementation: **0 failing endpoints**, WHS +0.585 ns, DRC clean.

## Test Infrastructure

### RTL Testbenches (52 files)

| Testbench | What it tests |
|-----------|---------------|
| `tb_c930_soc.sv` | Full SoC with firmware boot (11 tests: NPU GEMM, cache coherency, MMIO) |
| `tb_c930_soc_full.sv` | Full SoC with DDR controller |
| `tb_arb_bskid_equiv.sv` | Dual-DUT arbiter equivalence (strict + random modes, 1200+ txns) |
| `tb_hazard_equiv.sv` | Retimed hazard unit vs golden reference (300K cycles) |
| `tb_npu_core_fp16.sv` | NPU FP16 GEMM precision |
| `tb_l2_coherent.sv` | L2 cache coherence protocol |
| `tb_quad_isolated.sv` | Quad-core isolation |
| `tb_ptm_c_lockstep.sv` | PTM-C error model lockstep |

### Full SoC Test Suite (11 tests)

The firmware-driven `make soc` runs 11 tests exercising:
1. CPU boot from bootrom
2. DDR stub initialization
3. UART output
4. NPU0 integer GEMM (single shape)
5. NPU0 FP16 GEMM
6. NPU0 multi-shape sweep
7. NPU1 integer GEMM (if ENABLE_NPU1=1)
8. NPU0 + NPU1 dual-operation
9. Cache coherency (known failure — 28 expected FAILs)
10. MMIO stress (known failure — 28 expected FAILs)
11. DDR stress with mixed traffic (known failure — 54 expected FAILs)

Tests 9–11 have expected failures that match the baseline exactly, confirming no regression.

## Design Notes

Detailed design documentation lives in `c930/doc/`:

- **Architecture:** `c930_full_soc_architecture.md`, `c930_architecture.md`
- **Multi-core:** `multicore_architecture_plan.md`, `c930_core_scaling.md`
- **NPU:** `npu_optimization_design_note.md`, `npu_act_stage_design_note.md`
- **Error model:** `pta_error_model_design_note.md` (PTM-C drift/crosstalk)
- **Integration:** `phase7_integration_guide.md`, `phase7_roadmap.md`
- **Tapeout:** `grx930_tapeout_readiness.md`

## Circuit Diagrams

```bash
cd c930

# Generate interactive HTML hierarchy diagram
python build/gen_schematics.py rtl build/schematics

# Generate SVG block diagram
python build/gen_svg_diagram.py
```

Open `build/schematics/c930_hierarchy_schematic.html` in any browser for an interactive, color-coded hierarchy tree with timing stats and resource bars.

For gate-level PDFs (individual LUTs, FFs, BRAMs):
1. Open Vivado GUI with `build/vivado/c930_artix7.xpr`
2. Window → Schematic
3. Navigate to any subsystem → File → Export → Schematic → PDF

## FPGA vs ASIC

**FPGA (current):** Fully synthesized and routed on xc7a200tfbg484-1. BRAM-based DDR stub provides 64 KB for firmware boot. Ready for hardware validation.

**ASIC (future):** The design targets Xilinx primitives (LUTRAM, BRAM, DSP48). An ASIC flow would require:
- Standard cell library (SkyWater SKY130, TSMC N28, etc.)
- Technology mapping of Xilinx primitives to SRAM macros
- DFT (scan chains, JTAG, BIST)
- Clock tree synthesis and physical design
- Tapeout ($10K–$30K MPW shuttle, $100K+ full mask set)

## Git Workflow

- **`main`** — Production branch, FPGA-synthesized, timing-closed
- **Feature branches** — `npu/*`, `l2-bram`, etc.
- **Auto-retry driver** — `synth_xilinx/run_full_wsl_retry.sh` (heals MAC, relaunches Vivado on failure)

## License

Proprietary — kubeworkz. See repository settings for access control.
