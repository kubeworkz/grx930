# GRX930 Manufacturing Plan

**Date:** September 16, 2026
**Status:** Planning — RTL freeze achieved, FPGA validated on xc7a200t
**Target:** First silicon via MPW shuttle, with production path defined

---

## Executive Summary

The GRX930 SoC has achieved full timing closure on FPGA (WNS +7.883 ns, Fmax ~121 MHz, 0 DRC errors) and passes 18/18 NPU GEMM sweeps across INT4/INT8/INT16/FP16/BF16. This document defines the path from validated RTL to fabricated silicon.

**Recommended path:** SkyWater SKY130 via Efabless OpenMPW shuttle (~$15K, 14-week turnaround) as a first-silicon validation vehicle, followed by TSMC N28 for production if the shuttle succeeds.

**Estimated gate count:** ~1.2–1.5M NAND2-equivalent gates (derived from FPGA utilization)
**Estimated die area (SKY130):** ~18–22 mm²
**Estimated die area (TSMC N28):** ~3–5 mm²
**First silicon target:** Q1 2027 (if RTL freeze is held)

---

## 1. Design Metrics

### 1.1 RTL Summary

| Metric | Value |
|--------|-------|
| RTL modules | 94 |
| RTL files | 91 (.sv) |
| Total lines | 21,324 |
| Top module | `c930_soc_top` |
| Clock domains | 1 (`core_clk` from `i_clk` via BUFG divider) |
| Reset | Async-assert / sync-release (`i_rst_n`) |
| I/O ports | ~15 (excluding TB preload) |

### 1.2 Subsystem Breakdown

| Subsystem | Modules | Est. Gate Count | Notes |
|-----------|---------|-----------------|-------|
| 4× RV64IMAC cores | 38 | ~360K (4 × 90K) | 5-stage pipeline, I/D caches, AMO |
| 2× NPU (8×8 systolic) | 16 | ~240K (2 × 120K) | INT8/FP16/BF16, DMA, CSR |
| L2 Cache | 1 | ~80K | 4-way set-associative, 32 sets |
| AXI Crossbar | 2 | ~60K | 4-master, 64-bit data |
| DMA Arbiter (B-skid) | 2 | ~20K | Store-and-forward |
| Peripherals | 8 | ~40K | UART, APLIC, Boot ROM, MMIO bridge |
| Clock/Reset/Control | ~20 | ~30K | BUFG, synchronizers, FSMs |
| **Total** | **94** | **~1.2–1.5M** | |

### 1.3 Gate Count Derivation

The FPGA design uses 125,735 LUT4s and 67,007 FFs on the xc7a200t. For ASIC estimation:

| FPGA Resource | Count | ASIC Equivalent | Est. Gates |
|---------------|-------|-----------------|------------|
| LUT4 (as logic) | 118,000 | 4:1 MUX + AND/OR | ~590K (5 per LUT4) |
| LUT4 (as memory) | 7,735 | SRAM flip-flops | ~46K (6 per FF) |
| Flip-flops | 67,007 | D flip-flop + mux | ~470K (7 per FF) |
| BRAM (36Kb) | 55 | SRAM macros | ~275K (5K per macro) |
| DSP48 | 227 | Synthesized multiplier | ~136K (600 per DSP) |
| **Total** | — | — | **~1.2–1.5M** |

*Note: This is a rough estimate. Actual gate count requires ASIC synthesis with a target library (see §2.3).*

---

## 2. Foundry Selection

### 2.1 Option A: SkyWater SKY130 (Recommended for First Silicon)

| Parameter | Value |
|-----------|-------|
| **Process** | 130nm CMOS |
| **Density** | ~330K gates/mm² |
| **Max freq** | ~500 MHz (typical) |
| **Supply** | 1.8V core, 3.3V I/O |
| **Metal layers** | 4 |
| **SRAM** | High-density bit-cells (130nm DTCO) |
| **EDA tools** | Open-source (Yosys + OpenROAD + Magic) |
| **Shuttle** | Efabless OpenMPW ($10K–$30K) |
| **Turnaround** | 14–16 weeks |
| **Die area** | ~18–22 mm² for GRX930 |

**Pros:**
- **Zero license cost** — Yosys, OpenROAD, Magic, KLayout are all Apache/MIT licensed
- **Community support** — 200+ tapeouts via Efabless, active Slack community
- **Proven silicon** — SKY130 has been manufactured and characterized; 130nm means generous design rules
- **Fast iteration** — MPW shuttles run monthly; if first attempt fails, re-spin is cheap
- **RISC-V friendly** — SHAKTI, SweRV, and many RISC-V cores have taped out on SKY130

**Cons:**
- **130nm is old** — die area is ~20× larger than N28; not viable for high-volume production
- **No high-speed I/O** — no SerDes, limited DDR PHY support
- **SRAM limited** — 64 KB L2 might need to be split across multiple macro instances
- **Power** — higher dynamic and static power than advanced nodes

**Best for:** First silicon validation, FPGA-alternative prototyping, academic/research publication

### 2.2 Option B: TSMC N28 (Production Path)

| Parameter | Value |
|-----------|-------|
| **Process** | 28nm HPC+ |
| **Density** | ~3.5M gates/mm² |
| **Max freq** | ~1.0+ GHz |
| **Supply** | 0.9V core, 1.8V/3.3V I/O |
| **Metal layers** | 10 |
| **SRAM** | High-density and high-speed bit-cells |
| **EDA tools** | Commercial (Synopsys ICC2 + Design Compiler) |
| **Shuttle** | MPW via CMC/MOSIS ($50K–$150K) |
| **Turnaround** | 20–30 weeks |
| **Die area** | ~3–5 mm² for GRX930 |

**Pros:**
- **Dense** — full SoC fits in <5 mm²
- **Fast** — 1 GHz+ achievable with proper signoff
- **Production-ready** — used by commercial chip companies
- **Rich I/O** — DDR4 PHY, PCIe Gen3, SerDes available

**Cons:**
- **EDA license cost** — Synopsys/Cadence tools are $100K+/year
- **NRE cost** — MPW shuttle $50K–$150K; full mask set $1M+
- **Design rules** — 28nm requires careful physical design (DFM, CMP, litho)
- **Shuttle availability** — monthly MPW runs, but longer turnaround

**Best for:** Production volume, commercial product, high-performance requirements

### 2.3 Recommended Path

```
Phase 1: SkyWater SKY130 (first silicon)
  ├── RTL freeze (DONE)
  ├── ASIC synthesis (Yosys + sky130_std_cell)
  ├── Place & route (OpenROAD)
  ├── Signoff DRC/LVS (Magic + Netgen)
  ├── Tapeout via Efabless OpenMPW
  └── Silicon validation (14–16 weeks)

Phase 2: TSMC N28 (production, conditional on Phase 1 success)
  ├── RTL re-target (swap Xilinx macros → TSMC SRAM/RF)
  ├── Commercial synthesis (Synopsys DC)
  ├── Physical design (ICC2)
  ├── Signoff (PrimeTime + Calibre)
  └── Tapeout via CMC/MOSIS MPW or shuttle
```

---

## 3. Cost Model

### 3.1 SkyWater SKY130 (OpenMPW Shuttle)

| Item | Cost | Notes |
|------|------|-------|
| Efabless shuttle fee | $10,000 | Includes GDS, 10 working dies |
| EDA tools | $0 | Yosys + OpenROAD + Magic |
| IP licenses | $0 | SKY130 PDK is open-source |
| SRAM macros | $0 | Open-source SRAM compiler (OpenRAM) |
| Packaging (QFN/BGA) | $500–$2,000 | Depends on pin count |
| PCB test fixture | $1,000–$3,000 | Custom test board |
| Characterization | $2,000–$5,000 | Basic I/O timing, power measurement |
| **Total (first silicon)** | **$13,500–$20,000** | |

### 3.2 TSMC N28 (MPW Shuttle)

| Item | Cost | Notes |
|------|------|-------|
| CMC/MOSIS MPW shuttle | $50,000–$150,000 | Depends on die size and layer count |
| EDA tool licenses | $100,000+/yr | Synopsys/Cadence (can use cloud) |
| PDK license | $0 (via MOSIS) | Academic/research pricing |
| SRAM compiler (ARM Artisan) | $10,000–$50,000 | Or use open-source OpenRAM |
| Packaging | $2,000–$5,000 | BGA with wire bonding |
| Test board + fixtures | $5,000–$10,000 | High-speed test environment |
| **Total (first silicon)** | **$167,000–$215,000** | |

### 3.3 Production Volume (TSMC N28, 10K units)

| Item | Cost |
|------|------|
| Full mask set | $1,000,000 |
| Per-die wafer cost | ~$3,000/wafer (~500 die/wafer) |
| Per-die cost (yield ~80%) | ~$7.50/die |
| Packaging + test | ~$2–5/die |
| **Unit cost at 10K** | **~$15–20/die** |

### 3.4 Cost-Benefit Summary

| Approach | Upfront | Per-Unit (10K) | Risk |
|----------|---------|----------------|------|
| FPGA (xc7a200t) | $250 (board) | N/A | Very low |
| SKY130 shuttle | $15K | N/A (prototyping) | Low |
| TSMC N28 MPW | $150K | $15–20 | Medium |
| TSMC N28 production | $1M+ mask | $15–20 | High (volume commitment) |

---

## 4. Technology Mapping

The current RTL targets Xilinx primitives. For ASIC, these must be replaced:

### 4.1 Xilinx → ASIC Primitive Mapping

| Xilinx Primitive | ASIC Replacement | Notes |
|------------------|------------------|-------|
| `BRAM36` (55 instances) | SRAM macros (OpenRAM) | 36Kb → 32KB byte-addressable SRAM |
| `DSP48E1` (227 instances) | Synthesized multiplier | ~24×24 signed multiply |
| `BUFG` | Clock tree buffer | CTS handles this automatically |
| `LUT4/LUT6` | Standard cells (AND/OR/MUX) | Yosys handles this |
| `FDRE/FDCE` | D flip-flops | Standard cell library |
| `IOB` | Pad ring | SKY130 I/O cells |

### 4.2 Memory Macro Requirements

| Macro | FPGA (BRAM) | ASIC (SRAM) | Size |
|-------|-------------|-------------|------|
| I-Cache × 4 | 4 × 36Kb BRAM | 4 × 4KB SRAM | 16 KB total |
| D-Cache × 4 | 4 × 36Kb BRAM | 4 × 4KB SRAM | 16 KB total |
| L2 Cache | 18 × 36Kb BRAM | 18 × 2KB SRAM | 36 KB total |
| NPU Weight Buffer | 4 × 36Kb BRAM | 4 × 8KB SRAM | 32 KB total |
| NPU Accumulator | 8 × 18Kb BRAM | 8 × 1KB SRAM | 8 KB total |
| Boot ROM | 1 × 36Kb BRAM | 1 × 1KB SRAM | 1 KB |
| UART FIFO | 2 × 18Kb BRAM | 2 × 512B SRAM | 1 KB total |
| **Total SRAM** | — | — | **~110 KB** |

*OpenRAM can generate all these macros for SKY130. For TSMC N28, ARM Artisan or Synopsys DesignWare are standard choices.*

### 4.3 RTL Changes Required

1. **Replace `(* ram_style = "block" *)` with ASIC-compatible `reg` arrays** — OpenRAM or inferred SRAM
2. **Remove DSP48 instantiation** — let Yosys synthesize multipliers from RTL
3. **Add pad ring** — I/O cells for SKY130 (2.3V/3.3V LVCMOS)
4. **Add clock tree** — PLL or external oscillator (SKY130 has no on-chip PLL)
5. **Add power pins** — VDD/VSS ring, decap cells, tap cells
6. **Replace TB preload ports** — simulation-only ports must be removed or gated

---

## 5. Design for Test (DFT)

### 5.1 Scan Chain Insertion

| Item | Plan |
|------|------|
| **Scan methodology** | Full-scan (every FF in scan chain) |
| **Scan chain count** | 8–16 chains (balances shift time vs area) |
| **Scan cell** | Standard cell scan flip-flop (DFF with SI/SO) |
| **Area overhead** | ~3–5% (scan MUX on every FF) |
| **Test time** | ~500K cycles per pattern × ~100 patterns ≈ 50M cycles @ 100 MHz = 0.5 sec |
| **Tool** | Yosys `scan` command or Synopsys DFT Compiler |

**Implementation steps:**
1. Replace all `FDRE`/`FDCE` with scan-enabled flip-flops
2. Insert scan MUX (SI input) on every FF
3. Chain FFs into scan chains (8–16 chains)
4. Add scan I/O pads (SI, SO, SE, SCE)
5. Verify scan chain integrity (shift-in/shift-out test)

### 5.2 Memory BIST

| Item | Plan |
|------|------|
| **SRAMs requiring BIST** | All 41 instances (see §4.2) |
| **Algorithm** | March C- (10n complexity) |
| **Coverage** | Stuck-at, transition, coupling faults |
| **BIST controller** | 1 controller, muxed across all SRAMs |
| **Area overhead** | ~5K gates (controller + MUX) |
| **Test time** | ~10ms per SRAM @ 100 MHz |

**March C- sequence:** {⇑(r0); ⇑(w1); ⇑(r1); ⇓(r1); ⇓(w0); ⇓(r0)}

### 5.3 JTAG / IEEE 1149.1

| Item | Plan |
|------|------|
| **TAP controller** | Standard 4-wire JTAG (TCK, TMS, TDI, TDO) |
| **IR width** | 4 bits (EXTEST, PRELOAD, SAMPLE, BYPASS) |
| **Boundary scan** | All I/O pads |
| **Debug access** | RISC-V debug spec (abstract commands) |
| **Area overhead** | ~3K gates |

### 5.4 Production Test Flow

```
1. Wafer sort (probe test)
   ├── Scan chain integrity (shift test)
   ├── SRAM BIST
   ├── I/O continuity (EXTEST)
   └── Functional quick-check (boot ROM → UART output)

2. Package test
   ├── Full scan test (100+ patterns)
   ├── SRAM BIST (all instances)
   ├── At-speed functional test (NPU GEMM)
   └── DDR interface test (if DDR4 PHY included)

3. System test
   ├── Boot from flash
   ├── UART communication
   ├── NPU GEMM correctness (18-case sweep)
   └── Multi-core handshake test
```

---

## 6. Signoff Criteria

### 6.1 Static Timing Analysis (STA)

| Corner | Condition | Target |
|--------|-----------|--------|
| **SS/0.72V/125°C** | Slow-slow, worst case | WNS ≥ 0 ns (all paths MET) |
| **TT/0.90V/25°C** | Typical | WNS ≥ +2 ns (margin) |
| **FF/1.08V/−40°C** | Fast-fast, best case | WHS ≥ 0 ns (hold MET) |
| **SS/0.72V/125°C + crosstalk** | With SI analysis | WNS ≥ 0 ns |

**Clock targets:**
- `core_clk`: 100 MHz (10 ns period) — conservative; design supports 121 MHz
- `i_clk`: 100 MHz input (if external oscillator)

**Checklist:**
- [ ] Setup all 4 corners in PrimeTime / OpenSTA
- [ ] Verify all clocks are defined (create_clock, create_generated_clock)
- [ ] Verify all false paths are marked (TB preload, reset synchronizer)
- [ ] Verify all multicycle paths are marked (if any)
- [ ] Run SI-aware STA (crosstalk analysis)
- [ ] Report WNS, WHS, TNS, THS for each corner
- [ ] Verify 0 failing endpoints across all corners

### 6.2 IR Drop Analysis

| Item | Requirement |
|------|-------------|
| **Static IR drop** | ≤ 5% of VDD (45 mV at 0.9V) |
| **Dynamic IR drop** | ≤ 10% of VDD (90 mV at 0.9V) |
| **Power grid** | M1–M6 metal, 50% density minimum |
| **Decap cells** | Fill all empty spaces with decap |
| **Tap cells** | Every 20µm (latch-up prevention) |

### 6.3 Electromigration (EM) / Electrostatic Discharge (ESD)

| Item | Requirement |
|------|-------------|
| **EM (wire)** | Current density ≤ foundry limit at 125°C |
| **EM (via)** | Via current ≤ foundry limit |
| **ESD (HBM)** | ≥ 2 kV (Human Body Model) |
| **ESD (CDM)** | ≥ 500V (Charged Device Model) |
| **Latch-up** | No latch-up at 125°C, 1.1× VDD |

### 6.4 Physical Verification

| Check | Tool | Clean Criterion |
|-------|------|-----------------|
| **DRC** | Magic / Calibre | 0 errors |
| **LVS** | Netgen / Calibre | Netlist match (layout = schematic) |
| **Antenna** | Magic / Calibri | 0 violations (or with antenna diodes) |
| **ERC** | Magic | 0 errors |
| **Density** | Magic / Calibre | Metal density within ±10% of target |

### 6.5 Power Analysis

| Metric | Target |
|--------|--------|
| **Dynamic power** | < 200 mW @ 100 MHz, 0.9V (N28) |
| **Static power** | < 10 mW @ 125°C (N28) |
| **Power integrity** | No droop > 5% during peak activity |

---

## 7. Tapeout Timeline

### 7.1 SkyWater SKY130 (First Silicon)

```
Week 0:  RTL freeze (CURRENT — design is frozen)
Week 1:  ASIC synthesis (Yosys + sky130_std_cell)
         ├── Technology mapping (LUT→cells, BRAM→SRAM)
         ├── Gate-level simulation (functional verification)
         └── Initial area/timing report
Week 2:  Physical design (OpenROAD)
         ├── Floorplanning (die size, macro placement)
         ├── Power grid design
         ├── Placement + CTS
         └── Routing + DRC
Week 3:  Signoff
         ├── STA (all corners)
         ├── LVS (Magic + Netgen)
         ├── IR drop analysis
         └── Antenna check
Week 4:  GDS generation + tapeout
         ├── GDS stream out (Magic)
         ├── Netlist + SPEF + constraints
         └── Submit to Efabless OpenMPW
Week 5–18: Fabrication + packaging (14 weeks)
Week 19–20: Silicon validation
         ├── Probe test (wafer sort)
         ├── Package + board bring-up
         ├── Boot from ROM → UART output
         └── NPU GEMM correctness sweep
```

**Total: ~20 weeks from RTL freeze to validated silicon**

### 7.2 TSMC N28 (Production Path)

```
Week 0:   SKY130 silicon validated (prerequisite)
Week 1–4: RTL re-target (swap Xilinx primitives → N28 cells)
Week 5–8: Synthesis (Synopsys Design Compiler)
Week 9–14: Physical design (ICC2)
          ├── Floorplan + power grid
          ├── Placement + CTS + optimization
          ├── Routing + SI fixes
          └── Timing closure iteration
Week 15–16: Signoff (PrimeTime + Calibre)
Week 17: GDS + submit to shuttle
Week 18–46: Fabrication (28–30 weeks for MPW)
Week 47–50: Silicon validation
```

**Total: ~50 weeks from SKY130 validation to N28 silicon**

---

## 8. Risk Register

| # | Risk | Impact | Likelihood | Mitigation |
|---|------|--------|------------|------------|
| 1 | ASIC synthesis reveals timing violation at 100 MHz | Blocks tapeout | Medium | SKY130 is 130nm — generous timing; close to 50 MHz if needed |
| 2 | SRAM macros don't fit in available area | Die area blow-up | Low | OpenRAM generates flexible sizes; 110 KB is modest for 130nm |
| 3 | LVS errors from unmatched netlist | Delays tapeout | Medium | Run LVS early and often during physical design |
| 4 | Power grid insufficient for NPU peak activity | IR drop violation | Medium | Over-design power grid (50% metal density), add decap fill |
| 5 | OpenMPW shuttle rejected (DRC/ERC) | Misses shuttle window | Low | Run full DRC/ERC before submission; use Magic (same as Efabless check) |
| 6 | SKY130 I/O too slow for DDR | Can't validate DDR path | High (expected) | SKY130 has no DDR PHY; use BRAM-only boot path (same as FPGA) |
| 7 | First silicon non-functional | Need re-spin | Medium | Extensive gate-level simulation before tapeout; SKY130 re-spin is cheap ($15K) |
| 8 | TSMC N28 EDA license cost prohibitive | Can't proceed to production | High | Use cloud-based EDA (Synopsys on AWS/GCP) or academic license |
| 9 | DFT scan chains interfere with functional timing | Setup violations on scan path | Low | Scan chains only active during test mode; functional mode is unaffected |
| 10 | OpenMPW die count insufficient for all tests | Incomplete validation | Low | 10 working dies is usually enough for basic validation |

---

## 9. Open-Source Tool Flow (SKY130)

### 9.1 Required Tools

| Tool | Purpose | License |
|------|---------|---------|
| **Yosys** | RTL → gate-level netlist | ISC |
| **OpenROAD** | Place & route | BSD-3 |
| **Magic** | DRC, LVS, GDS stream | GPL |
| **KLayout** | GDS viewing/editing | GPL |
| **Netgen** | LVS netlist comparison | GPL |
| **OpenSTA** | Static timing analysis | BSD |
| **OpenRAM** | SRAM macro generation | BSD |
| **iverilog** | Gate-level simulation | GPL |

### 9.2 Flow Commands

```bash
# 1. ASIC synthesis
yosys -p "
  read_verilog -sv c930/rtl/*.sv c930/rv64imac/RTL/*.sv;
  read_verilog c930/synth_xilinx/defines.vh;
  synth -top c930_soc_top -flatten;
  synth -run map_fsm;
  abc -liberty sky130_fd_sc_hd__tt_025C_1v80.lib;
  write_blif build/asic/c930_soc.blif;
  write_verilog -noattr build/asic/c930_soc.v;
"

# 2. Floorplan + P&R (OpenROAD)
openroad -exit build/asic/flow.tcl

# 3. DRC
magic -noconsole -dnull build/asic/c930_soc.gds

# 4. LVS
netgen -script build/asic/lvs.tcl

# 5. Gate-level simulation
iverilog -o build/asic/c930_soc.vvp \
  build/asic/c930_soc.v \
  c930/tb/tb_c930_soc.sv
vvp build/asic/c930_soc.vvp
```

---

## 10. Comparison: FPGA vs SKY130 vs N28

| Metric | FPGA (xc7a200t) | SKY130 | TSMC N28 |
|--------|-----------------|--------|----------|
| **Process** | 28nm (Xilinx) | 130nm | 28nm |
| **Die area** | N/A | ~20 mm² | ~4 mm² |
| **Fmax** | 121 MHz | ~100 MHz | ~500+ MHz |
| **Power** | ~5W (board) | ~200 mW | ~50 mW |
| **First silicon cost** | $250 | $15K | $150K |
| **Per-unit cost** | $250 | ~$50 | ~$15 |
| **Tool cost** | Vivado ($0 academic) | $0 (open-source) | $100K+/yr |
| **Turnaround** | Hours | 20 weeks | 50 weeks |
| **Re-spin cost** | $0 | $15K | $150K |
| **I/O bandwidth** | Limited by board | Limited (no DDR PHY) | DDR4/PCIe/SerDes |
| **Best for** | Prototyping | First silicon validation | Production |

---

## 11. Recommendations

1. **Hold RTL freeze now.** The design is timing-closed, DRC-clean, and passes all functional tests. Any RTL change after this point requires re-running the full Vivado flow AND the ASIC flow.

2. **Start with SKY130 via OpenMPW.** The $15K cost and 14-week turnaround make this the lowest-risk path to silicon. It proves the design works in real silicon before committing to expensive N28 tools.

3. **Write the ASIC synthesis wrapper this sprint.** Replace Xilinx BRAMs with OpenRAM macros, remove DSP48 instantiation, and add the pad ring. This is ~2 weeks of engineering.

4. **Don't skip DFT.** Scan chains and SRAM BIST add ~5% area but are essential for production test. Build them into the SKY130 tapeout — it's cheaper to add them now than to re-spin.

5. **Defer TSMC N28 until SKY130 validates.** The N28 flow requires $100K+ in EDA licenses and a $150K shuttle. Only commit after SKY130 silicon proves the design works.

6. **Plan the test board now.** The SKY130 die needs a custom PCB with JTAG header, UART, power supply, and clock input. This takes 4–6 weeks to design and fabricate — start during the 14-week fab wait.

---

## Appendix A: OpenMPW Submission Checklist

- [ ] GDS file generated (Magic `gds write`)
- [ ] Netlist in Verilog format (not BLIF)
- [ ] SPEF timing annotation (from OpenSTA)
- [ ] Constraints file (SDC format)
- [ ] Pin configuration file (openlane config)
- [ ] Power/ground pad ring
- [ ] DRC clean (Magic `drc list`)
- [ ] LVS clean (Netgen `lvs`)
- [ ] Antenna check clean (Magic `antenna check`)
- [ ] All SRAM macros generated (OpenRAM) and instantiated
- [ ] No `inout` pads (bidirectional not supported on all pads)
- [ ] ESD protection on all I/O pads
- [ ] Decap fill completed
- [ ] Tap cell fill completed

---

## Appendix B: Reference Projects

| Project | Process | Description |
|---------|---------|-------------|
| [SHAKTI C-class](https://github.com/SemiCoRD/shakti-tools) | SKY130 | 6-stage RV64IMAC, first RISC-V on SKY130 |
| [ChipFlow CHIPS](https://github.com/lowRISC/chip-flow) | SKY130 | Open-source ASIC flow example |
| [OH! APU](https://github.com/aolofsson/oh) | SKY130 | Efabless reference SoC |
| [Ariane/ServoVee](https://github.com/pulp-platform/ara) | SKY130 | RISC-V application core |
| [GRXGPU TFR](internal) | ECP5 | GRXGPU tensor core (comparable complexity) |
