# Quad-core + NPU on GF180MCU — submission scope

**What this is.** The scope of putting the four-core SoC on silicon as its own part, with the
three things that decide it costed: the ASIC wrapper, the SRAM macros the memories need, and the
pad ring. It is a scope, not a plan of record: no RTL, config or flow file was changed to write
it, and the largest item in it — which slot the part goes in — is now answered: none of
wafer.space's, so the route is a foundry shuttle (§8). **Decided 28 October 2026:** the memory
architecture is configuration B (§4) — main memory off-chip, L1 32 KB and L2 64 KB as macros,
86.4 mm² of content.

**Basis.** `c930_soc_top.sv` (the 4-core SoC), the wafer.space project template and pre-check in
this tree, and the two measured area figures already in the record: one core at **5.95 mm²** of
cells (12.93 mm² core × 46 %) and one NPU at **8.864 mm²** (`Claude outputs/npu_gf180_area.md`,
25 Oct 2026, memories excluded). Every macro number below is read from the PDK's own LEF `SIZE`
lines in the pre-check image, not estimated.

---

## 1. The finding that reorders the work: a 2×4 slot is not a slot

`npu_gf180_area.md` recommended **2×3 minimum, 2×4 comfortable** by extrapolating a geometry
model — core = die − 884 µm per axis — from the 1×1 slot. The model is sound; the product is not
there. Four independent places in this tree agree that **the largest slot that exists is 1×1**:

| Source | What it says |
|---|---|
| `wafer-space/gf180mcu-precheck`: `precheck.py` `--slot` choices | `["1x1", "0p5x1", "1x0p5", "0p5x0p5"]` — and nothing else |
| same repo, `scripts/klayout/check_size.py` | four branches, else `[Error]: Unsupported slot size` |
| same repo, pad-opening check | the mask is `mask_<slot>.gds`; there are four |
| project template `Makefile` | `AVAILABLE_SLOTS = 1x1 0p5x1 1x0p5 0p5x0p5` |
| `c930/doc/gf180mcu_area_budget_review.md` §1 (Run 3 specification) | the four-slot table, largest **1×1: 19.67 mm² usable, 12.92 mm² core, 56 pads** |

**Answered 27 October 2026: there is no such slot.** wafer.space's position is that the four
published sizes *are* the catalogue — no larger slot, no contiguous multi-slot block diced as a
single design, no custom large-die service — and the pre-check has no path for a die that is not
one of the four. The reply puts the maximum die at **3932 × 5122 µm, 20.12 mm²**, which is the 1×1
slot itself. So this is not a resize, a config edit or a wait: **the quad-core cannot be a
wafer.space part at any size they publish.** It is a foundry-shuttle or private-run submission, and
the enquiry that replaces the slot question is `quadcore_gf_enquiry.md` (§8). The record of the
question, and the numbers it was asked with — a die of **7.864 × 20.488 mm** (161 mm², eight 1×1
units), a core of 137 mm², ~30 bond-out signals and CoB as the assembly option — is in
`quadcore_slot_enquiry.md`.

Two things follow, and neither depended on the answer:

* **The 46 mm² figure is not the part's area.** It undercounts by ~2.5× once the memories are
  real (§4). A 2×4 would be the wrong answer even if it existed.
* **No slot in the published catalogue holds this SoC in any multi-core form** — the arithmetic
  is in §8 — so "which slot" is a genuine fork, not a resize.

---

## 2. What the part is

`c930_soc_top.sv`, unmodified in intent, at its simulated parameters:

| Block | Count | Note |
|---|---|---|
| `riscv_core_top` (RV64IMAC, 5-stage) | 4 | CPU1–3 reset to ROM parking loops at `0x0001_0020/60/A0` |
| `c930_npu_top` → `c930_npu_core` + `c930_systolic_array` + `c930_npu_act` | 2 | `NUM_ROWS/COLS 8`, `DIN_W 16`, `ACC_W 48`, `MAX_M/K/N 8/16/12`, `NUM_BANKS 4` |
| `c930_l2` (MSI-lite directory, write-through) | 1 | 512 sets × 4 ways × 32 B = 64 KB |
| `c930_axi_crossbar` | 1 | 4 masters × 4 slaves |
| `c930_axi_dma_arb`, `c930_mmio_arb`, `c930_mmio_bridge` | 3 | the ten-master topology in `c930_core_scaling.md` §1 |
| `c930_ddr` | 1 | **64 KB byte array**, 3 data ports + AXI slave |
| `c930_bootrom` | 1 | 1 KB, `CORE_RESET_PC` |
| `c930_uart` (16550) | 1 | the only external stimulus today |
| APLIC | 1 | 3 sources: NPU0, NPU1, UART |

**There is no FPGA memory controller to remove.** A search of `c930_soc_top.sv` for `MIG`,
`DDR3` and `DSP48` returns zero matches: the DDR is `c930_ddr`, a synthesizable byte array with
cache-line read ports. That is good news for the wrapper and bad news for the area (§4).

**Board-facing signals.** `clk`, `rst_n`, UART TX/RX, and the eight NPU status outputs
(`o_npu{,1}_{busy,done,error,irq}`). The SoC has **no GPIO and no external interrupt pin** —
unlike `grx930_test_chip`, which has both. The 1×1 part's GPIO heartbeat and `i_ext_irq` pad do
not transfer; the eight NPU status lines take their place, and they are already outputs, so the
pad map costs no RTL.

---

## 3. The ASIC wrapper

`chip_core_quad.sv`, in the shape of `chip_core_grx930.sv`: instantiate `c930_soc_top` inside the
template's `chip_top` ring, map pads, tie off what the design does not use. The work is small
and mostly bookkeeping of the kind the adapter lint already automates — **with four exceptions,
each of which is a real edit**:

1. **`CLK_DIV` must be 1.** With `CLK_DIV > 1` and `SYNTHESIS` defined, `c930_soc_top` elaborates
   a Xilinx `BUFG` (`g_clkgen`), which no GF180 library can resolve. Either set `CLK_DIV=1` or
   move the `BUFG` behind an FPGA-only ifdef. This is a hard failure at synthesis, not a warning.
2. **The testbench ports must be tied off or ifdef'd.** `i_tb_wr_en/addr/data` and `i_tb_rd_addr`
   are declared unconditionally in the module header (their comment says "active only when
   `USE_TB_PRELOAD=1`"). Tie them to constants in the wrapper so the logic behind them prunes;
   do not leave them floating.
3. **`initial` blocks and `$readmemh` must be excluded from the ASIC build.** `c930_ddr` zeroes
   its array in an `initial` and optionally loads `INIT_FILE`; the cache memories and the L2 do
   the same. On silicon there is no preloaded main memory — the **1 KB ROM is the only resident
   code**, and the quad-core's firmware has to arrive over the UART (64 KB at 115200 baud is
   ~5.7 s). The loader protocol is a firmware deliverable of this part, not a port of the
   testbench.
4. **The ROM content changes.** The 1×1 flow stages `asic_core/` *minus* `c930_bootrom.sv` and
   `bootrom_wrapper.sv`, and takes its ROM from `grx930_test_chip_rom.sv` instead — because the
   SoC's `c930_bootrom` is a `$readmemh`-initialised array, which an ASIC ROM cannot be. The
   quad-core needs the same treatment: a real ROM module (4-hart boot, parking loops, UART
   loader) generated by `tools/gen_bootrom.py`, with the same "boots standalone" evidence the
   1×1 part has.

Plus the standing items: the SoC's file closure has never been through a 5 V GF180 flow. It
already produced two latent defects the first time the NPU met yosys 0.66 (a ranged `parameter
integer` and a DSP48E1 stub modelling the wrong function — `npu_gf180_area.md`). Expect more of
that class, and retire it with the existing `run_adapter_lint.sh` pattern plus a
synthesis-only probe before any flow run.

**Effort:** days for the wrapper and pad map; days for the lint/probe loop; the ROM and the
loader are firmware work measured in weeks, and they are on the critical path for bring-up, not
for tapeout.

---

## 4. The memories — this is the part's area

Every array in the SoC, with the PDK's own macro arithmetic. The macros are `x8` wide with byte
write masks (`m8wm1`), all 431.86 µm long, and **deeper is denser**:

| Macro | Size (µm) | mm² | bits/mm² |
|---|---|---:|---:|
| `sram64x8m8wm1` | 431.86 × 232.88 | 0.1006 | 5,090 |
| `sram128x8m8wm1` | 431.86 × 268.88 | 0.1161 | 8,819 |
| `sram256x8m8wm1` | 431.86 × 340.88 | 0.1472 | 13,913 |
| **`sram512x8m8wm1`** | 431.86 × 484.88 | **0.2094** | **19,562** |

All four are present under **gf180mcuD** in the pre-check image with `lef gds lib verilog cdl
spice mag maglef` views and the three 5 V corners the template names (`tt_025C_5v00`,
`ff_n40C_5v50`, `ss_125C_4v50`) — checked, not assumed; the open item in
`gf180mcu_area_budget_review.md` §5 is closed. At 512 B per macro the capacities in play are
0.42 mm²/KB.

| Array | Capacity | Read style | Macro mapping | Macro area |
|---|---:|---|---|---:|
| 4 × I-cache + 4 × D-cache (`INDEX_WIDTH 7`) | 32 KB | 2-cycle contract already assumed | 64 × sram512x8 | 13.4 mm² |
| `c930_l2` data (4 ways × 4 words × 512 sets) | 64 KB | **registered read** — bank is `always_ff` | 128 × sram512x8 | 26.8 mm² |
| `c930_ddr` `mem[0:65535]` | 64 KB | **3 ports, combinational reads** | not mappable as-is | 26.8 mm² |
| NPU operand banks (`a_mem`, `b_mem` ×2 banks ×2 NPUs) | 2.5 KB | **combinational read** | FFs (≈2.7 mm²) | — |
| boot ROM | 1 KB | — | ROM cells | — |

Three findings, in order of consequence:

**The L2 maps cleanly.** Its data array is already `bank[0:NUM_SETS-1]` with a registered capture
and a 1-cycle serve (`c930_l2.sv:238-242`), 512 deep, 64 bits wide, byte-write-masked — exactly
the macro's port shape. 8 macros per word × 4 words × 4 ways = 128 macros.

**The main memory does not.** `c930_ddr` is a byte array with two cache-line read ports (256-bit)
and a 64-bit write port, read combinationally in three places (`assign s_axi_rdata = {mem[...]}`).
Keeping it as FFs is not an option at 64 KB (524 kbit at 7.7 kbit/mm² ≈ 68 mm²); making it macros
means **banking it behind a port schedule** — an RTL rework with a throughput consequence, and
the same non-blocking read the 256-bit line wants has to come from 32 parallel macros or a burst.

**The NPU banks are cheap but blocking.** They are tiny (1.25 KB per NPU at the SoC's
parameters) so FFs are affordable, but their reads are combinational (`act_comb[...] = a_mem_0[...]`),
which is why the flat synthesis OOMed on them. Two conditions: synthesise with **the SoC's**
`MAX_M/K/N` (8/16/12 — not the module's 64/256 defaults), and if these ever move to macros they
need a pipeline stage in the systolic feed.

**The totals, and the correction to the brief:**

| | mm² | Basis |
|---|---:|---|
| 4 cores (cells) | 23.79 | measured, 5.95 × 4 |
| 2 NPUs (cells, memories excluded) | 17.73 | measured, 8.864 × 2 |
| NPU operand RAM as FF | 2.66 | 20.5 kbit ÷ 7.7 kbit/mm² |
| L1 macros (32 KB) | 13.40 | |
| L2 macros (64 KB) | 26.80 | |
| main-memory macros (64 KB) | 26.80 | after the §4 rework |
| crossbar, directory, APLIC, UART, ROM, glue | ~2 | estimate |
| **total (configuration A)** | **≈113 mm²** | against the brief's 46 mm² → **2.5×**; configuration B, below, is **86.4 mm²** |

The brief counted the L2 as "~3 mm² estimate" and the 64 KB main memory as nothing at all. SRAM
at this node is ~19.6 kbit/mm² at best, so **the two 64 KB arrays alone are 53.6 mm²** — more
than the brief's entire part. That single fact is what §8 turns on.

**The platform publishes a ceiling, and it agrees.** wafer.space's technology page lists per-slot
SRAM capacity: a **1×1 holds 40 KB of 5 V `sram512x8` (80 blocks)**, and Run 1's most SRAM-heavy
design used 60 of them. This part wants 160 KB — 320 blocks, **4× one full slot's entire SRAM
capacity** — so the memories alone rule out every catalogue slot before the ~46 mm² of logic cells
is considered. The denser community 3.3 V blocks (1 KB each; 108 KB per slot, still short of
160 KB) would narrow the gap at the price of a second voltage domain and non-foundry IP: a lever
to investigate, not a plan.

### The decision: configuration B, frozen 28 October 2026

Row area is what standard cells can use — macro blocks are lost to placement and to their PDN
keep-out. In a 2×4 (137 mm² core) the three configurations were:

| Configuration | Macros | Total | Cell utilisation of the remaining rows | Verdict |
|---|---:|---:|---:|---|
| **A** as simulated: 64 KB L2, 64 KB main, 8 KB/core L1 | 67.0 | 113.2 | 46.2 / 69.8 = **66 %** | rejected: denser than the 46 % failing to route today |
| **B** main memory off-chip (board SRAM), rest unchanged | 40.2 | 86.4 | 46.2 / 96.6 = **48 %** | **decided** |
| **C** B + L2 → 16 KB + L1 → 1 KB/core | 10.1 | 56.3 | 46.2 / 126.8 = **36 %** | the fallback if the routing surrogate fails |

**Decided: B.** What it freezes — each of these is now a parameter the wrapper, the floorplan and
the board are written against, not a question:

| Item | Frozen value | Consequence |
|---|---|---|
| main memory | off-chip, 64 KB, 32 B lines | `MEM_BYTES 65536` stays the address window; 26.8 mm² of macro leaves the die |
| L1 | 8 KB/core (`INDEX_WIDTH 7`), 32 KB | 64 × `sram512x8`, 13.40 mm² |
| L2 | 64 KB (512 sets × 4 ways × 32 B) | 128 × `sram512x8`, 26.80 mm² |
| NPU operand banks | flops, 1.25 KB per NPU | 2.66 mm²; synthesised at the SoC's `MAX_M/K/N` 8/16/12 |
| boot | 1 KB ROM + UART loader | unchanged by the decision |
| **content** | **86.4 mm²** (46.2 cells + 40.2 macros) | against 113.2 mm² for A |

**What it does to area — and the correction it forces on the price.** B removes 26.8 mm² of
*content*; it does not remove die area at the density already costed. Filling in the same
`core = cells/utilisation + macros`, `die = core/0.85` model the §1 geometry came from:

| | rows needed | core | die (÷0.85) | at €913/mm² |
|---|---:|---:|---:|---:|
| B at 48 % (the 2×4 core) | 96.6 | 136.8 | 161 | ≈€147k |
| B at 46 % (today's density) | 100.4 | 140.6 | 165 | ≈€151k |
| B at 42 % | 110.0 | 150.2 | 177 | ≈€161k |
| A at 46 % (the same density) | 100.4 | 167.4 | 197 | ≈€180k |

Two readings, both wanted:

* **At equal density B is 32 mm² of die smaller** than A (165 against 197), because the macro is
  gone from the placed area *and* from the rows it would have consumed.
* **At the costed 161 mm² die, B is at 48 %** — two points *denser* than the 46 % that is failing
  to route at 1×1 today. B does not buy routability at that size; it buys it at ~165 mm² (46 %)
  and comfortably at ~177 mm² (42 %). Those cost €4–14k more than the original 161, which is
  noise against the tooling spend either route needs (§8), so **the die is sized for density, not
  for the tightest area**: 165 mm² is the planning number, 177 mm² the relief valve, and C (36 %)
  the fallback if neither routes.

**The die shape is now ours.** The 2×4 outline existed to tile eight wafer.space unit slots; a
foundry shuttle has no such grid. 165 mm² is a ~12.9 × 12.9 mm square (161 mm² is 12.7 mm), which
retires the 20.5 mm dimension that made reticle-field fit an open question (§9) and makes the part
easier to bond. The `7.864 × 20.488 mm` in the enquiries is configuration A's footprint; what the
supplier is asked about from here is a ~13 mm square part of about the same area.

**The RTL is a file swap, not a rework.** `c930_ddr`'s port list — two 256-bit cache-line read
ports, a 64-bit byte-strobed write port, and a 64-bit AXI4 full slave — is already an interface
four implementations sit behind in this tree (`rtl/c930_ddr.sv`, `sim/c930_ddr_verilator.sv`,
`synth/c930_ddr_stub.sv`, `rtl/c930_ddr3l.sv`), which is why `c930_soc_top` and every testbench
elaborate unchanged when one is swapped for another. Configuration B adds a fifth:
`rtl/c930_extmem.sv`, same ports, holding the cache→AXI bridge and the arbiter `c930_ddr3l.sv`
already carries (its 751 lines are the bridge, the arbiter and a Xilinx MIG layer) with the MIG and
its `ui_clk` crossing replaced by a single-clock synchronous-SRAM FSM. Simulation keeps
`c930_ddr.sv`; the ASIC build names the new file.

### The board contract this freezes

Main memory is the first thing on the board the SoC cannot boot without, so its interface belongs
to the decision rather than to a later detail:

| | Frozen |
|---|---|
| port | `em_dq[63:0]` bidirectional, `em_a[15:0]` (byte address, 13 bits used for the 8K-deep array), `em_bw_n[7:0]`, `em_ce_n`/`em_we_n`/`em_oe_n`, `em_clk` out — **92 pads** |
| width | 64-bit, because the AXI4 slave and the dcache write port already are: a 32 B line fills in 4 beats, and the controller stays a protocol adapter rather than a width converter |
| clocking | one domain, the core clock — the DDR3L controller needs a CDC only because MIG runs at 200 MHz, and there is no MIG here |
| rate | 8 B/cycle, 200 MB/s at 25 MHz; a line fill is 4 beats plus address setup, against 2 cycles for the on-chip array it replaces |
| parts | 8K × 64 bits = 64 KB as several synchronous 5 V SRAMs in parallel (four ×16 or eight ×8 — the exact width is a parts-availability question, not an architecture one); a single 64-bit-wide 5 V SRAM is not a catalogue part, and 3.3 V parts would add a second I/O domain |
| boot | unchanged: 1 KB ROM, then 64 KB of firmware over UART (~5.7 s at 115200) |

The cost shows in the pad ring: 92 memory pads against ~28 for everything else takes the ring from
the ~4 % §5 describes to ~19 %, so the bring-up pads that section argues for are still affordable
but no longer free.

---

## 5. The pad ring

**Geometry is easy.** Configuration B's planning die is a ~12.9 mm square (§4); at the foundry
pads' 75 µm pitch between 355 µm corners its perimeter holds ~670 pad sites. The 1×1 ring uses 18
of them for power and 56 for signals (74 sites in all); B adds a 92-pad memory port, so with ~18
power, ~10 signals and room to bring up it is ~19 % occupied and mostly `__fill1`. Padding out a
ring is not the problem.

**Everything downstream of the ring is.** The ring is generated from a slot definition —
`librelane/slots/slot_<slot>.yaml` (`DIE_AREA`, `CORE_AREA`, `PAD_SOUTH/EAST/NORTH/WEST`), a block
in `src/slot_defines.svh`, and the template's `scripts/padring.py` — and the template ships four
slot files, none of them this die. A ~13 mm square needs a fifth definition of our own, and the
pre-check has no mask for it at all — which is §1's fact again: the quad-core is not a wafer.space
part, so the pre-check is not its gate. The
wafer.space IP cells the submission must carry (`qrcode_id`, `shuttle_id`, `project_id`, `marker`,
`logo`) are placed in `macros_5v.yaml`; the marker and logo follow `$DIE_AREA` expressions, but
**qrcode at (26,26), shuttle_id at (26,175.6) and project_id at (175.6,26) are absolute 1×1
coordinates** and their encoded content is issued per submission — so that is an external item
too, not a config edit.

**What is still open here** is not the ring size but what the spare sites are *for*: the 1×1 part
has ten board signals on one edge and boots blind over UART. Even after B's memory port the ~670
site ring has ~540 left, and the cheapest thing to buy with them is bring-up bandwidth (a second
UART, a couple of IRQs, or a 2-wire debug port), given that the first silicon will be debugged
over whatever is bonded out. That is the last board decision left, and it changes the board the
same way the memory port did.

---

## 6. Open risks

| # | Risk | Number / evidence | Mitigation |
|---|---|---|---|
| 1 | **No wafer.space slot exists — closed 27 Oct 2026** | pre-check accepts 4 slots; catalogue max is 1×1 (20.12 mm²), whose whole 5 V SRAM budget is 40 KB against this part's 160 KB | Route it to a foundry shuttle: `quadcore_gf_enquiry.md` asks GF for a written area limit and price on a 161 mm² die (§8) |
| 2 | Memory area undercounted | 67 mm² of macro; total 113 mm², 2.5× the brief | **Closed 28 Oct:** B freezes 86.4 mm², 40.2 mm² of it macro (§4) |
| 3 | Routing at 48 % | B is 48 % on the 2×4 core, 46 % at a 165 mm² die, against 46 % failing at 1×1 today | the surrogate run (§7 step 3); C is the fallback |
| 4 | `c930_ddr` → external controller | 3 ports, combinational reads; 64 KB moves off-chip | `c930_extmem.sv` behind `c930_ddr`'s port list (§4) |
| 5 | First-macro-flow risk | placement, PDN straps over macros, antenna, 5LM pin access, STA vs vendor `.lib` | The template's macro steps exist; retire the risk on a 1×1 surrogate (§7) |
| 6 | Never synthesised as a chip top | NPU alone produced 2 real defects on first contact | lint + yosys probe on the closure, days |
| 7 | Reset/CTS for 4 cores | the 1×1 reset-tree fix is core-level; this part has four reset domains + 2 NPUs | `librelane_reset_cts_patch.py` generalises, but it is 4× the nets |
| 8 | Hold | −2.44 ns on both engines at 1×1 | unresolved; scales with the design |
| 9 | 25 MHz over 4 cores | FPGA closed ~121 MHz, but on 7-series; GF180 5 V 7-track is slower | STA is an experiment, not an assumption; the part boots either way |
| 10 | Boot/bring-up | ROM is the only resident memory; 64 KB over UART ≈ 5.7 s | loader firmware; debug pads (§5) |
| 11 | Board | ~13 mm square die, ~30 bonds plus the 92-pad memory port, CoB markers issued per submission | the board is now specified by §4's contract rather than inherited from a slot |
| 12 | **Price/schedule** | 8× a 1×1 slot's area basis; public floor €913/mm² (≈€147k), GF terms unpublished | `quadcore_gf_enquiry.md` (§8) |

---

## 7. Sequencing

0. **Ask the foundry question** (`quadcore_gf_enquiry.md`) — wafer.space answered "no" on 27 Oct
   (§1). Nothing below is wasted by the answer; what it decides is price and date — the die shape
   is ours to fix since configuration B (§4).
1. ~~**Freeze the memory architecture**~~ **Done 28 Oct 2026: configuration B** (§4) — main memory
   off-chip, L1 8 KB/core, L2 64 KB, NPU banks in flops, 86.4 mm² of content, and the board
   contract that goes with it.
2. **Write `chip_core_quad.sv` + tie-offs** and retire §3's four exceptions; run the adapter lint
   and a synthesis-only probe on the full closure.
3. **Retire the macro-flow risk cheaply, on a 1×1 surrogate.** The 1×1 slot has room for the
   macro *step* even though it has no room for the quad-core: swapping part of the 1×1 part's FF
   cache array for ~2 KB of `sram512x8` **frees** area rather than costing it (2 KB of FF array
   is ~2.1 mm² at the tree's own 7.7 kbit/mm², against 0.84 mm² of macro), and forces the whole
   macro path — `MACROS`/`PDN_MACRO_CONNECTIONS`, PDN straps over a macro, manual macro
   placement, antenna, STA against the foundry `.lib` — to work at the utilisation we already
   route. This is the single best-value experiment available and it does not need the slot
   question answered.
4. **Author the pad ring and the die/floorplan definition for the foundry route**, with the board
   contract's signal list. On a wafer.space part these come from the template (`slot_1x1.yaml`,
   the per-slot pad mask, the per-submission IP cells); on a shuttle they are ours to draw and the
   foundry issues the mask, seal-ring and scribe rules (§8).
5. **Memory conversion**: `rtl/c930_extmem.sv` behind `c930_ddr`'s port list (§4), then L1/L2
   macro tiling on the L2's existing bank structure.
6. **PDN + floorplan at the chosen configuration**, then STA, then routing. The unknown is
   routing at 36–48 % with macro blocks; nothing before step 3 tells us anything about it.

Steps 1–3 are ours and startable now — 1 is done. Steps 4–6 are large; step 4 needs the board
contract, not a supplier.

---

## 8. The route, now that wafer.space is closed

**Shrink to fit a catalogue slot — impossible.** The largest published core is 12.92 mm². Even one
core plus one NPU is 5.95 + 8.86 = 14.8 mm² of cells before any macro or memory: a multi-core
part does not fit any slot wafer.space publishes, in any flavour.

**The single-die routes, priced as far as public information goes.**

| Route | Status | Price for a ~161–165 mm² die | What decides it |
|---|---|---|---|
| **GlobalFoundries GlobalShuttle**, 180 nm | GF's MPW page lists 180 nm, and the GF180MCU PDK's own manufacturing page says GF runs an MPW programme on this process. **No published area limit, price, quantity or cadence** — GF routes schedules through GF Connect and directs MPW questions to its contact form | unpublished; “up to 100 dice” described as part of the base fee | a written answer to `quadcore_gf_enquiry.md` |
| **EUROPRACTICE / imec**, GF180MCU (“Open PDK”) | published in the 2026 price list: area-priced, **6 mm² minimum billed**, two GF180MCU registration dates in 2026. Access to GF through EUROPRACTICE runs via **Fraunhofer IIS** and is **NDA-gated and entity-only** (signed NDA + questionnaire; GF contracts with companies and research institutes, not individuals) | **€913/mm² → ≈€147k** standard, €830/mm² → **≈€134k** discounted, *if a design this size is accepted* | whether their GF180 maximum die size allows 161 mm² (their published block sizes are fixed per technology) — and who signs the NDA |
| **Private full-mask run** | the fallback if neither shuttle accepts the size | mask set ~$100k (market range 60–500k) + a 25-wafer lot at ~$1.5k ≈ **$137k** before backend; budget **$150–250k** | whether the part is worth that before a shuttle can carry it |
| **Four 1×1 dies (MCM)** | the only route that uses a catalogue we know exists | **$8,000 × 4** (Run 3 basis) + CoB $1,500 each + a board | **it does not build this part** — see below |

**Where the two stand, as of 27 October 2026.** GF's GlobalShuttle MPW form was submitted the same
day — its question box caps at 700 characters, so what went was the short version, and the seven
questions in `quadcore_gf_enquiry.md` follow if they ask for detail. The EUROPRACTICE email to
Fraunhofer IIS **went out the same day** from `dave@gridworkz.com` (20 lines, five numbered
questions; Gmail confirmed it and it sits in Sent), so both suppliers now hold the question. Both
answers land in that mailbox, and they fold into the rows above rather than into a separate note.
The NDA pack the EUROPRACTICE order is gated on — the GF `NDA_Request_Form` and the questionnaire,
filled from this project's record, the entity's own details included — **went to Fraunhofer IIS on
27 October 2026** (message id `1a17fc34b4f1a94c`; both attachments hash-verified against the prepared
files), so what this step waits on now is the entity's signature. Receipts in
[`nda_pack/`](nda_pack/).

**What the supplier is being asked changed on 28 October.** Configuration B (§4) keeps about the
same area but is a ~13 mm square part instead of A's `7.864 × 20.488 mm`, and both enquiries were
sent with A's footprint. The area question stands as written; the shape question in
`quadcore_gf_enquiry.md` should be read against the square, and that is the correction to send
with the NDA signature rather than a second enquiry.

**The four-die module does not carry the accelerators.** The arithmetic is unforgiving: one core is
5.95 mm² of cells and one NPU **8.86 mm²**, so a die holding one of each needs **14.81 mm²** against
a 1×1 core of **12.92 mm²** — at 100 % cell utilisation, before a single memory block. And 160 KB is
320 `sram512x8` blocks against the 80 a full slot holds. So four 1×1 slots buy **four single-core
dies** — in effect four of the vehicle we are taping out, with the shared L2 and the main memory
moved onto the board — not four cores plus two accelerators. That is a real architecture (a
four-chiplet module over the GRXIConnect link, external memory on the board) and at ~$32k it is an
order of magnitude cheaper than any large-die route; but it is a different part, and calling it
“the quad-core” would be wrong. The accelerators would need slots of their own and would make the
array a separate die on the link.

**Waiting is not a route.** Whether a later wafer.space run adds larger slots is their commercial
decision, and the answer above is the published catalogue as it stands. The part has to be planned
against a supplier who has quoted it.

---

## 9. What this does not settle

* **Whether 86.4 mm² routes** in 5LM with 40.2 mm² of macro — 48 % on the 2×4 core, 46 % at 165 mm²,
  against the 46 % failing at 1×1 today. That C (36 %) is the arithmetic fallback, not evidence; the
  surrogate in §7 step 3 is the closest cheap evidence available.
* **The vendor `.lib` corners' effect on STA.** The macros ship with 1.62–5.5 V corners; which
  three the flow picks and what they do to the 40 ns budget is unmeasured.
* ~~**Field fit.**~~ **Retired by configuration B** (§4): 165 mm² is a ~12.9 mm square, and the
  20.5 mm dimension existed only to tile eight wafer.space slots. The enquiries still quote A's
  `7.864 × 20.488 mm` footprint — that is the one supplier sentence needing correcting (§8).
* **Price and date.** EUROPRACTICE publishes €913/mm² for GF180MCU — ≈€147k at 161 mm², ≈€151k at
  B's 165 mm² planning die, ≈€161k at the 177 mm² relief valve — and two 2026 registration dates;
  GF's own terms are unpublished. Neither is a quote for a die this size.
* **Whether the quad-core should be a *product* at all**, as opposed to the accelerator-slice
  reading in `c930_core_scaling.md` §5 — where core count is close to irrelevant and the array's
  utilisation is the lever. This document costs the physical part; it does not argue for it.

## Reproduce

```sh
# Macro geometry and density, under the variant the flow uses:
docker run --rm --entrypoint sh ghcr.io/wafer-space/gf180mcu-precheck -c '
  B=/workspace/gf180mcu/ciel/gf180mcu/versions/*/*/gf180mcuD/libs.ref/gf180mcu_fd_ip_sram
  for f in $B/lef/*.lef; do printf "%-46s %s\n" "$(basename $f .lef)" "$(grep -m1 "^ *SIZE" $f)"; done
  ls $B/lib | grep -E "tt_025C_5v00|ff_n40C_5v50|ss_125C_4v50"'

# The slot ceiling, from the tool we have to pass:
grep -n "choices" c930/asic_gf180mcu/tools/gf180mcu-precheck/precheck.py
grep -n "Unsupported slot size" c930/asic_gf180mcu/tools/gf180mcu-precheck/scripts/klayout/check_size.py

# The memory implementations behind one port list (configuration B adds a fifth):
ls c930/rtl/c930_ddr.sv c930/sim/c930_ddr_verilator.sv c930/synth/c930_ddr_stub.sv \
   c930/rtl/c930_ddr3l.sv

# The SoC's memory and port inventory:
grep -n "A_DEPTH\|B_DEPTH" c930/rtl/c930_npu_core.sv
grep -n "logic \[7:0\] mem" c930/rtl/c930_ddr.sv
grep -c "MIG\|DDR3\|DSP48" c930/rtl/c930_soc_top.sv      # 0
```
