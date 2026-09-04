# GRX930 Full SoC — Architecture Specification

**Status:** Planning document. Existing RTL is verified on FPGA; this spec extends it to a complete SoC.
**Scope:** Single-chip RISC-V AI SoC with integrated NPU, memory controller, and I/O.
**Existing codebase:** `c930/rtl/`, `rv64imac/RTL/`, `c930/synth_xilinx/`.

---

## 1. What We Have Today

### 1.1 Existing RTL inventory

| Module | Source | Description |
|--------|--------|-------------|
| `riscv_core_top` | `rv64imac/RTL/` | RV64IMAC, 5-stage in-order, I/D caches (256-bit lines), AMO/LR/SC, MMIO port |
| `c930_npu_top` | `c930/rtl/` | 8×8 systolic GEMM engine (INT8/INT16/FP16/BF16), AXI4 DMA master, AXI4-Lite CSR slave, command queue (depth 4), cross-GEMM prefetch |
| `c930_soc_top` | `c930/rtl/` | Integrates CPU + NPU + DDR stub + MMIO bridge. 64 KB BRAM DDR, flat memory map |
| `c930_mmio_bridge` | `c930/rtl/` | CPU uncached MMIO ↔ AXI4-Lite (32-bit CSR access, 2–3 cycle latency) |
| `c930_ddr` | `c930/rtl/` | Behavioral DDR stub: byte-array, dual-port (CPU cache + AXI4 slave), 64 KB |
| `c930_ddr3l` | `c930/rtl/` | DDR3L MIG wrapper for Arty A7-100T (256 MB), cache-line + AXI4 slave ports |
| Boot firmware | `c930/sw/` | `npu_boot.c` (tiny GEMM kick-off), `npu_test.c` (shape sweep), `npu_tile.c` (tiling demo) |
| XDC constraints | `c930/synth_xilinx/` | Arty A7-100T pin map, clock tree, DDR3L MIG constraints |
| Verilator models | `c930/sim/` | `c930_soc_verilator.sv`, `c930_npu_dpi.sv` (DPI wrapper for grxcp integration) |

### 1.2 Existing interfaces

```
CPU (riscv_core_top)
  ├── I-cache port  ──► 256-bit line read  ──► DDR
  ├── D-cache port  ──► 256-bit line read  ──► DDR
  │                  ──► 64-bit write (byte strobe) ──► DDR
  └── MMIO port     ──► c930_mmio_bridge ──► AXI4-Lite ──► NPU CSR

NPU (c930_npu_top)
  ├── AXI4-Lite slave  ◄── MMIO bridge (CSR programming)
  ├── AXI4 full master ──► DDR (DMA read/write A/B/C)
  └── IRQ/busy/done/error ──► SoC top (LED / interrupt controller)
```

### 1.3 What's missing for a real SoC

| Category | What's missing | Priority |
|----------|---------------|----------|
| **Bus fabric** | No interconnect — CPU and NPU are hardwired to a single DDR stub | Critical |
| **Memory controller** | DDR stub is 64 KB BRAM; real DDR3/DDR4 needs MIG PHY or external controller | Critical |
| **Boot ROM** | Firmware loaded via testbench `$readmemh`; no real boot path | High |
| **UART / debug** | No serial console, no JTAG, no printf | High |
| **Interrupt controller** | NPU IRQ wired to LEDs; no APLIC/IMSIC, no priority, no nesting | Medium |
| **Clock/reset** | Single 100 MHz oscillator, no PLL, no power domains | Medium |
| **Multi-NPU** | Single NPU instance; no interconnect for N× NPU scaling | Low (ASIC phase) |
| **I/O peripherals** | No GPIO controller, no timer, no SPI master (beyond boot flash) | Low |

---

## 2. Proposed SoC Architecture

### 2.1 Target platforms

| Platform | Part | Use case | NPU config |
|----------|------|----------|------------|
| **FPGA prototype** | Artix-7 200T (XC7A200TFBG484-1) | Development, grxcp integration, software bring-up | 8×8 INT8/FP16, 64 KB DDR stub |
| **ASIC (future)** | TBD (28nm or below) | Production server chip | 8×8 or 16×16, real DDR4/HBM, multiple NPU instances |

### 2.2 Full SoC block diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          GRX930 SoC                                         │
│                                                                             │
│  ┌──────────────┐                                                          │
│  │  Boot ROM    │  (1 KB, holds reset vector + boot firmware)              │
│  │  0x0000_0000 │                                                          │
│  └──────┬───────┘                                                          │
│         │                                                                   │
│  ┌──────▼───────┐    ┌──────────────────────────────────────────────┐      │
│  │  AXI4-Lite   │◄──►│  riscv_core_top (RV64IMAC)                   │      │
│  │  Slave Port  │    │  5-stage in-order, I/D caches, AMO/LR/SC    │      │
│  │  (MMIO)      │    │  CSR: mstatus, mtvec, mepc, mcause, mie     │      │
│  └──────┬───────┘    └──────┬──────────────────────────┬────────────┘      │
│         │                   │                          │                    │
│         │              I-cache port (256b)        D-cache port (256b)      │
│         │                   │                          │                    │
│  ┌──────▼───────────────────▼──────────────────────────▼──────────────┐    │
│  │                    AXI4 Interconnect (Fabric)                      │    │
│  │                                                                    │    │
│  │  M0: CPU I-cache    S0: Boot ROM (1 KB)                           │    │
│  │  M1: CPU D-cache    S1: DDR Controller (real DRAM or BRAM stub)   │    │
│  │  M2: NPU DMA        S2: MMIO Region (0x4000_0000+)                │    │
│  │                      S3: UART / Debug                              │    │
│  └──────┬───────────────────┬──────────────────────────┬──────────────┘    │
│         │                   │                          │                    │
│  ┌──────▼───────┐  ┌───────▼────────┐  ┌──────────────▼──────────────┐    │
│  │  NPU         │  │  DDR Memory    │  │  Peripherals                │    │
│  │  c930_npu_top│  │  Controller    │  │                              │    │
│  │  8×8 INT8/   │  │                │  │  ┌────────────────────────┐  │    │
│  │  FP16/BF16   │  │  Real DDR3L    │  │  │  UART (115200 8N1)    │  │    │
│  │              │  │  or 64KB stub  │  │  │  (printf / debug)      │  │    │
│  │  AXI4 master │  │                │  │  └────────────────────────┘  │    │
│  │  (DMA A/B/C) │  │  AXI4 slave    │  │                              │    │
│  │              │  │  (NPU + CPU)   │  │  ┌────────────────────────┐  │    │
│  │  AXI4-Lite   │  │                │  │  │  Timer (mtime/mtimecmp)│  │    │
│  │  slave (CSR) │  │  I-cache port  │  │  │  (RISC-V priv spec)    │  │    │
│  │              │  │  D-cache port  │  │  └────────────────────────┘  │    │
│  │  IRQ ────────┤  │  AXI4 slave    │  │                              │    │
│  │  busy/done   │  │  (NPU DMA)     │  │  ┌────────────────────────┐  │    │
│  └──────────────┘  └────────────────┘  │  │  GPIO (LEDs, buttons)  │  │    │
│                                        │  └────────────────────────┘  │    │
│                                        │                              │    │
│                                        │  ┌────────────────────────┐  │    │
│                                        │  │  PLIC / APLIC          │  │    │
│                                        │  │  (interrupt routing)   │  │    │
│                                        │  └────────────────────────┘  │    │
│                                        └──────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Bus Architecture

### 3.1 Why a bus fabric is needed

The current `c930_soc_top` hardwires the CPU and NPU to a single DDR stub with no arbitration. This works because:
- CPU cache reads and NPU DMA reads/writes happen on different ports of `c930_ddr`
- The DDR stub has zero latency (combinational read, 1-cycle write)

With a real memory controller (multi-cycle latency, bank conflicts, refresh), we need:
1. **Arbitration** between CPU and NPU competing for DDR bandwidth
2. **Outstanding transaction support** (AXI4 burst length > 1)
3. **Address decode** to route Boot ROM, DDR, MMIO, UART to correct slaves
4. **Optional burst coalescing** for NPU DMA to improve DDR utilization

### 3.2 Recommended interconnect

**Option A: Simple crossbar (for FPGA prototype)**

A 3-master × 4-slave AXI4 crossbar with round-robin arbitration. Existing open-source: `axi_crossbar` from AXI Infrastructure IP (Alex Forencich / Foxt). ~2K LUTs on Artix-7.

```
M0: CPU I-cache ──┐
M1: CPU D-cache ──┤──► AXI4 Crossbar ──► S0: Boot ROM (1 KB, fixed latency)
M2: NPU DMA ─────┘                ──► S1: DDR Controller
                                   ──► S2: MMIO Region (APLIC + peripherals)
                                   ──► S3: UART (thin AXI4-Lite slave)
```

**Option B: AXI4 NIC / NoC (for ASIC)**

For a real chip with multiple NPU instances, use a network-on-chip (NoC) or AXI4 NIC with QoS. This is the "CHI coherent NPU port" mentioned in the roadmap.

### 3.3 Memory map (revised)

| Address Range | Size | Region | Access |
|---------------|------|--------|--------|
| `0x0000_0000 – 0x0000_03FF` | 1 KB | Boot ROM (reset vector + firmware) | Read-only |
| `0x0000_1000 – 0x0000_FFFF` | 60 KB | DDR (code + data + NPU buffers) | Read/Write |
| `0x4000_0000 – 0x4000_003F` | 64 B | NPU CSR (AXI4-Lite) | MMIO |
| `0x4000_1000 – 0x4000_100F` | 16 B | UART (tx/rx/data/status) | MMIO |
| `0x4000_2000 – 0x4000_200F` | 16 B | Timer (mtime/mtimecmp) | MMIO |
| `0x4000_3000 – 0x4000_300F` | 16 B | GPIO (leds/buttons/switches) | MMIO |
| `0x4000_4000 – 0x4000_4FFF` | 4 KB | APLIC (interrupt controller) | MMIO |
| `0x8000_0000 – 0xFFFF_FFFF` | 2 GB | External DDR (ASIC only, via MIG/HBM) | Read/Write |

---

## 4. Memory Subsystem

### 4.1 Boot ROM (1 KB)

A small block ROM holding:
1. **Reset vector** at `0x0000_0000`: initial PC, stack pointer setup
2. **Boot firmware**: copies DDR payload from flash (if present) or jumps to DDR code
3. **NPU self-test**: optional POST that runs a tiny GEMM and checks LEDs

For FPGA, initialize with `$readmemh("boot.hex")` from `c930_sw/`.

### 4.2 DDR controller options

| Option | Capacity | Latency | FPGA cost | Notes |
|--------|----------|---------|-----------|-------|
| **BRAM stub** (current `c930_ddr`) | 64 KB | 1 cycle | ~0 LUTs | Testbench only; no arbitration |
| **MIG 7 Series** (Arty A7) | 256 MB DDR3L | ~10–15 cycles | ~3K LUTs + MIG hard IP | `c930_ddr3l.sv` already has MIG wrapper |
| **AXI DDR4 controller** (ASIC) | GB+ DDR4/HBM | ~50–100 cycles | External PHY | For production chip |

**For the FPGA prototype:** Use the existing `c930_ddr3l.sv` MIG wrapper. The DDR3L controller exposes the same cache-line + AXI4 slave ports as the stub, so the SoC top-level needs only a compile-time switch:

```systemverilog
generate
  if (USE_REAL_DDR)
    c930_ddr3l #(...) u_ddr (...);
  else
    c930_ddr   #(...) u_ddr (...);
endgenerate
```

### 4.3 BRAM budget (Artix-7 200T)

| Component | BRAM36 | BRAM18 | Notes |
|-----------|--------|--------|-------|
| CPU I-cache (128 lines × 32B) | 2 | 0 | 4 KB |
| CPU D-cache (128 lines × 32B) | 2 | 0 | 4 KB |
| NPU a_mem (8×16 × 8b) | 0 | 1 | 128 B |
| NPU b_mem (16×12 × 8b) | 0 | 1 | 192 B |
| NPU c_mem (8×12 × 32b) | 0 | 1 | 384 B |
| Boot ROM (1 KB) | 0 | 1 | 1 KB |
| UART TX/RX FIFO (64B each) | 0 | 0 | LUTRAM |
| **Total** | **4** | **4** | **8 BRAM36 + 0 BRAM18** |
| **Available (200T)** | **365** | **730** | **1.1% utilization** |

BRAM is not a constraint. The NPU's systolic PEs use no BRAM at all (weights are in FFs for single-cycle read).

---

## 5. Peripheral Plan

### 5.1 UART (serial debug console)

**Requirement:** `printf`-style debug output from the CPU firmware.

**Implementation:** Simple 16550-compatible AXI4-Lite UART, ~400 LUTs.

| Register | Offset | Description |
|----------|--------|-------------|
| TX_DATA | 0x00 | Write byte to transmit |
| RX_DATA | 0x04 | Read byte received |
| STATUS | 0x08 | Bit 0: TX full, Bit 1: RX empty, Bit 2: TX done |
| CTRL | 0x0C | Baud divisor (default: 100 MHz / 115200 ≈ 868) |

**Pin mapping:** Arty A7 has FTDI FT2232H channel B directly connected:
- `D4` = `uart_rxd` (FPGA input ← FTDI TXD)
- `C4` = `uart_txd` (FPGA output → FTDI RXD)

**Firmware API:**
```c
#define UART_TX   (*(volatile u32 *)(0x4000_1000))
#define UART_RX   (*(volatile u32 *)(0x4000_1004))
#define UART_STAT (*(volatile u32 *)(0x4000_1008))

void uart_putc(char c) {
    while (UART_STAT & 1);  // wait for TX not full
    UART_TX = c;
}
void uart_puts(const char *s) { while (*s) uart_putc(*s++); }
```

### 5.2 Timer (mtime / mtimecmp)

**Requirement:** RISC-V privilege specification compliant timer for time-sharing and preemptive scheduling.

**Implementation:** 64-bit free-running counter + 64-bit comparator, generates external interrupt when `mtime >= mtimecmp`.

| Register | Offset | Description |
|----------|--------|-------------|
| MTIME_LO | 0x00 | Low 32 bits of free-running counter |
| MTIME_HI | 0x04 | High 32 bits |
| MTIMECMP_LO | 0x08 | Low 32 bits of comparator |
| MTIMECMP_HI | 0x0C | High 32 bits |

**Interrupt:** Wired to the PLIC/PLIC as a machine timer interrupt (`mip.MTIP`).

### 5.3 GPIO controller

**Requirement:** Directly control LEDs, read buttons/switches on the Arty board.

**Implementation:** 8-bit output (LEDs), 4-bit input (buttons), 4-bit input (switches).

| Register | Offset | Description |
|----------|--------|-------------|
| LED_OUT | 0x00 | Write LED state (bits [7:0]) |
| BTN_IN | 0x04 | Read button state (bits [3:0], active-high) |
| SW_IN | 0x08 | Read switch state (bits [3:0]) |
| LED_DIR | 0x0C | Direction register (1=output, 0=input, for future use) |

**Pin mapping (Arty A7):**
- LEDs: `H17`, `K15`, `J13`, `N14` (LD0–LD3)
- Buttons: `D18`, `E18`, `G17`, `M17` (btn[0]–btn[3])
- Switches: `J15`, `L16`, `M13`, `R15` (sw[0]–sw[3])

### 5.4 Interrupt controller (APLIC)

**Requirement:** Priority-based interrupt routing for NPU completion, UART RX, timer.

**Implementation:** Minimal APLIC subset (RISC-V AIA spec, Machine level only).

| Source | Priority | Description |
|--------|----------|-------------|
| 1 | Highest | Machine timer interrupt (mtimecmp) |
| 2 | Medium | NPU completion (o_irq) |
| 3 | Low | UART RX data available |

**Register map (APLIC base: `0x4000_4000`):**

| Offset | Name | Description |
|--------|------|-------------|
| 0x00 | source_priority[i] | Priority for source i |
| 0x0C | enable_m | Machine-level enable mask |
| 0x10 | threshold | Minimum priority to interrupt |
| 0x14 | claim | Read to claim, write to complete |

**Firmware API:**
```c
#define APLIC_BASE 0x40004000u
#define APLIC_CLAIM (*(volatile u32 *)(APLIC_BASE + 0x14))

void handle_irq(void) {
    u32 source = APLIC_CLAIM;  // read to claim
    switch (source) {
        case 1: handle_timer(); break;
        case 2: handle_npu_done(); break;
        case 3: handle_uart_rx(); break;
    }
    APLIC_CLAIM = source;  // write to complete
}
```

---

## 6. Clock and Reset Infrastructure

### 6.1 Clock domains

| Domain | Frequency | Source | Consumers |
|--------|-----------|--------|-----------|
| `sys_clk` | 100 MHz | Board oscillator (E3) | PLL input |
| `core_clk` | 50–100 MHz | PLL / CLK_DIV | CPU, NPU, all peripherals |
| `ddr_clk` | 200 MHz | MIG PLL | DDR controller PHY |
| `uart_clk` | 100 MHz | `core_clk` (shared) | UART baud generator |

**FPGA:** Use `CLK_DIV=2` as today (100 MHz → 50 MHz for core). MIG provides its own `ui_clk` (200 MHz / 4 = 50 MHz for DDR3L).

**ASIC:** PLL generates `core_clk` from external reference. Multiple power domains for future voltage/frequency scaling.

### 6.2 Reset sequencing

```
Power-on → i_rst_n = 0 (held by power monitor)
         → PLL locks → core_clk stable
         → MIG init complete → ddr_clk stable
         → Release i_rst_n → core begins at 0x0000_0000
```

The current `c930_soc_top` uses async-assert/sync-release on `i_rst_n`. This is correct for FPGA. For ASIC, add a proper reset controller (power-on reset + brown-out detection).

---

## 7. Firmware and Boot Flow

### 7.1 Boot sequence (FPGA prototype)

1. **Bitstream loads** from QSPI flash → FPGA configures → `i_rst_n` released
2. **CPU starts at `0x0000_0000`** (Boot ROM reset vector)
3. **Boot ROM firmware:**
   - Sets up stack pointer (top of DDR: `0x0000_FFF0`)
   - Copies `.data` section from Boot ROM to DDR (if applicable)
   - Jumps to `main()` in DDR (or stays in Boot ROM for tiny tests)
4. **`main()` programs NPU** via MMIO CSRs, polls STATUS, reads C results
5. **UART prints results** to serial console

### 7.2 Memory layout for firmware

```
Boot ROM (0x0000_0000 – 0x0000_03FF):
  0x0000: reset vector (j _start)
  0x0004: stack pointer init (li sp, 0x0000_FFF0)
  0x0008: _start: jump to DDR main() or stay in ROM
  
DDR (0x0000_1000 – 0x0000_FFFF):
  0x1000: .text (firmware code)
  0x8000: .data (constants, strings)
  0x9000: A matrix buffer (NPU operand)
  0x9100: B matrix buffer
  0x9200: C result buffer
  0xF000: Stack (grows down)
```

### 7.3 Toolchain

- **Compiler:** RISC-V GCC (`riscv64-unknown-elf-gcc`) — already used for `npu_boot.c`
- **Linker script:** Extend `link.ld` to support Boot ROM + DDR regions
- **Hex generation:** `objcopy -O verilog` → `$readmemh` for FPGA bitstream
- **For ASIC:** JTAG debug + OpenOCD for interactive debugging

---

## 8. FPGA Prototype Build Plan

### 8.1 Target: Arty A7-100T (XC7A200TFBG484-1)

**What exists:** Full Vivado flow (`c930/synth_xilinx/`), timing-clean at 100 MHz (WNS +8 ns), 53.5% LUTs.

**What to add:**

| Component | LUT cost (est.) | BRAM cost | Notes |
|-----------|----------------|-----------|-------|
| AXI4 crossbar (3×4) | ~2,000 | 0 | `axi_crossbar` from AXI IP |
| UART (16550-like) | ~400 | 0 | Minimal TX/RX + FIFO |
| Timer (mtime) | ~200 | 0 | 64-bit counter + comparator |
| GPIO (LEDs/buttons) | ~100 | 0 | Directly wired to pins |
| APLIC (interrupt ctrl) | ~300 | 0 | 3-source priority encoder |
| Boot ROM (1 KB) | ~100 | 0.5 | $readmemh init |
| **Total additions** | **~3,100** | **0.5** | |
| **Current design** | **~72,000** | **8** | |
| **New total** | **~75,100** | **8.5** | **56% of 134K LUTs** |

The 200T has headroom. The full SoC fits.

### 8.2 Vivado project additions

```
c930/synth_xilinx/
  create_project.tcl          (existing — extend with new sources)
  run_synth.tcl               (existing — unchanged)
  run_impl.sh                 (existing — unchanged)
  arty_a7_100t.xdc            (existing — add UART/timer/GPIO pins)
  ip/
    axi_crossbar_0/            (new — AXI4 interconnect)
    blk_mem_gen_0/             (new — Boot ROM, $readmemh init)
```

### 8.3 Build commands (updated)

```bash
cd c930/synth_xilinx
# 1. Create project (adds new RTL sources)
vivado -mode batch -source create_project.tcl

# 2. Synthesize
vivado -mode batch -source run_synth.tcl

# 3. Implement + bitstream
bash run_impl.sh

# 4. Program FPGA
openFPGALoader -b arty_a7_100t build/vivado/c930_soc_top.bit
```

---

## 9. ASIC Design Considerations (Future)

### 9.1 What changes from FPGA to ASIC

| Aspect | FPGA (current) | ASIC (future) |
|--------|----------------|---------------|
| DDR | MIG hard IP (256 MB) | DDR4/HBM PHY (GB+) |
| Clock | 100 MHz oscillator | PLL + clock tree synthesis |
| Reset | Button + synchronizer | POR + brown-out + scan |
| BRAM | Block RAM (limited) | SRAM macros (unlimited) |
| LUTs | Configurable LUTs | Standard cells |
| DSP | DSP48E1 (240) | Synthesized multipliers |
| I/O | FPGA pins (LVCMOS33) | Pad ring (DDR PHY, SerDes) |
| Power | Single voltage (3.3V core) | Multiple power domains |

### 9.2 ASIC-specific additions

- **JTAG debug:** RISC-V debug spec (abstract commands, trigger modules)
- **Scan design:** DFT scan chains for manufacturing test
- **BIST:** Memory built-in self-test for SRAMs
- **PLL:** On-chip clock generation from external reference
- **IO pads:** DDR4 PHY, SerDes (PCIe/CXL), GPIO pad ring
- **Power management:** Clock gating, power gating for unused NPU instances

### 9.3 Multi-NPU scaling (ASIC)

For a server-class chip, instantiate N NPU instances behind the AXI crossbar:

```
CPU ──► AXI Crossbar ──► NPU_0 (GEMM engine)
                    ──► NPU_1 (GEMM engine)
                    ──► NPU_2 (GEMM engine)
                    ──► NPU_3 (GEMM engine)
                    ──► DDR Controller (shared)
```

Each NPU gets its own CSR base address (`0x4000_0000 + i * 0x1000`) and independently dispatches GEMMs. The CPU firmware round-robins or event-drives across instances.

**At 4× NPU with 8×8 INT8 @ 500 MHz:**
- Per-NPU: 64 PEs × 500M MAC/s = 32 GOPS (INT8)
- Total: **128 GOPS** (INT8)
- With FP16: **64 GOPS** (FP16, 2 bytes/element)

---

## 10. Integration Checklist

### 10.1 For FPGA prototype (Phase 1)

- [ ] Write AXI4 crossbar wrapper (`c930_axi_fabric.sv`)
- [ ] Write UART RTL (`c930_uart.sv`) — 16550-compatible, ~400 LUTs
- [ ] Write timer RTL (`c930_timer.sv`) — 64-bit mtime/mtimecmp
- [ ] Write GPIO RTL (`c930_gpio.sv`) — LEDs, buttons, switches
- [ ] Write minimal APLIC (`c930_aplic.sv`) — 3-source priority encoder
- [ ] Write Boot ROM init (`c930_bootrom.sv`) — $readmemh from hex file
- [ ] Extend `c930_soc_top.sv` to integrate all peripherals
- [ ] Extend `arty_a7_100t.xdc` with UART/timer/GPIO pin constraints
- [ ] Extend Vivado project (`create_project.tcl`) with new sources
- [ ] Verify full SoC in Icarus testbench (`tb_c930_soc_full.sv`)
- [ ] Verify in Verilator (`c930_soc_verilator.sv`)
- [ ] Run Vivado synthesis + implementation on Arty A7-100T
- [ ] Program FPGA, verify UART output, NPU GEMM, LED behavior

### 10.2 For grxcp integration (Phase 2)

- [ ] Extend `c930_npu_dpi.sv` DPI wrapper for new peripherals
- [ ] Write grxcp backend driver (`npu_c930.cc`) — CSR programming, DMA setup
- [ ] Verify grxcp queue dispatch against RTL (sequential + pipelined)
- [ ] Run grxcp conformance tests on real FPGA via UART/JTAG
- [ ] Benchmark: measure GEMM throughput at 8×8 INT8/FP16/BF16

### 10.3 For ASIC (Phase 3, future)

- [ ] Replace DDR stub with DDR4 PHY + controller
- [ ] Add JTAG debug (RISC-V debug spec)
- [ ] Add PLL + clock tree synthesis
- [ ] Add DFT scan chains + BIST
- [ ] Multi-NPU instantiation (2× or 4×)
- [ ] Add PCIe/CXL endpoint (optional, for host attachment)
- [ ] ASIC tapeout preparation (timing closure, DRC, LVS)

---

## 11. Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| AXI crossbar adds latency to NPU DMA | Reduced GEMM throughput | Use registered crossbar, measure DMA_CT before/after |
| DDR3L MIG PHY limits Fmax below 50 MHz | CPU/NPU run slower | MIG ui_clk is independent; core clock unaffected |
| UART FIFO too small for printf burst | Dropped characters | 64B TX FIFO sufficient for short debug strings |
| APLIC priority inversion | Missed NPU completion interrupt | Use claim/register pattern, test with concurrent timer + NPU |
| Multi-NPU contention for DDR bandwidth | Scalability bottleneck | Add QoS per-NPU, or use HBM with multiple channels |
| Boot ROM too small for complex firmware | Cannot load DDR payload | Boot ROM does minimal setup; main firmware lives in DDR |

---

## 12. Summary: From What We Have to What We're Building

```
TODAY                              PLAN
─────                              ────
CPU + NPU + DDR stub               Full SoC with bus fabric
Hardwired, no arbitration          AXI4 crossbar (3×4)
64 KB BRAM "DDR"                   Real DDR3L (256 MB) or DDR4/HBM
No serial output                   UART (115200, printf debug)
No interrupts                      APLIC (3-source, priority)
No timer                           mtime/mtimecmp (RISC-V spec)
No GPIO abstraction                GPIO controller (LEDs/buttons)
Boot via $readmemh                 Boot ROM + JTAG (FPGA/ASIC)
Single NPU instance                N× NPU instances (ASIC)
FPGA-only                         ASIC-ready architecture
```

The existing RTL is the compute core. This spec wraps it in the infrastructure needed to run real software: bus fabric for arbitration, peripherals for I/O, interrupt controller for event-driven execution, and a boot path that starts from silicon, not from a testbench.

**Estimated effort for FPGA prototype:** 2–3 weeks of RTL + testbench work (bus fabric, UART, timer, GPIO, APLIC, boot ROM, integration testbench, Vivado build).

**Estimated effort for grxcp integration:** 1 week (DPI wrapper update, backend driver, conformance tests).
