# Production signoff plan — GRX930 test chip

**Status: NOT RUN. No production gate is complete.**
This plan is a sequence and evidence contract, not a result. A gate is complete only when its command has run on the frozen input, its full report is retained, its hash is recorded, and the named owner has signed the exit criteria.

## 1. Current facts that gate the plan

| Fact | Current state |
|---|---|
| Final merged GDS for the 8,168-drop candidate | **Absent.** `build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix16.gds` is the fix16 base. The selected `fix70` GDS is absent. `c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds` is explicitly marked **VOID** in its README and is not an input. |
| Final schematic/CDL | `c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl` exists (17,754,516 bytes). It must be regenerated from the frozen final netlist. |
| Final routed DEF | `build/lvs_chip/rebased_grx930_test_chip.def` exists, but `build/pnr_final29.log` ends with `DRT-0305` and no completed detailed route. It is not a production DEF. |
| Final SPEF | **Absent.** No `.spef` exists under `build/`. |
| DFT/ATPG | **Not inserted.** No scan chain, scan DEF, or ATPG pattern set exists. `dftc`, `tetramax`, and `yosys` are not on PATH in this environment. |
| Full-chip LVS verdict | **None.** The full run was stopped after more than 100 minutes. A crop is not a substitute. |
| Full DRC verdict | **None.** Only focused M1/M2/M3/V1/V2 decks have run. |
| Timing/power verdict | **None.** No multi-corner STA, IR, EM, crosstalk, or thermal report. |
| Foundry review | **None.** No tape-out review or approval. |

## 2. Owners

| Role | Owner | Responsibility |
|---|---|---|
| Design lead | ____________________ | Freezes RTL/netlist, resolves ECOs, signs the final GDS/CDL identity |
| DFT lead | ____________________ | Scan insertion, ATPG, BIST/boundary-scan evidence |
| Physical verification lead | ____________________ | Full LVS and full DRC runs, reports, waiver register |
| STA/power lead | ____________________ | Multi-corner STA, power, IR, EM, crosstalk, thermal |
| Tape-out manager | ____________________ | Foundry package, mask review, package/pinout, silicon qualification |
| Gridworkz signatory | Gridworkz | Recomputes input hashes and signs the G0 attestation; no Gridworkz connector is available in this session |

An owner name is required before the gate starts. An unsigned gate stays **NOT RUN**, even if a report exists.

## 3. Execution order

The technically correct order is:

```
G0 input freeze (pre-DFT snapshot)
  -> G1 DFT/ATPG insertion (mutates the netlist)
  -> G2 final GDS/CDL/DEF/SPEF freeze
  -> G3 full-chip LVS  ─┐
  -> G4 full-chip DRC  ─┴─ parallel after G2
  -> G5 multi-corner STA/power
  -> G6 foundry tape-out review
```

DFT insertion changes the netlist. Any LVS, DRC, or STA run made before G1 is a pre-DFT result and must be repeated after the scan netlist is frozen. If the DFT owner supplies a signed waiver that no scan insertion is required, the design lead must record that waiver before G2; it does not waive the ATPG or test-evidence gate.

## 4. Gates

### G0 — Input freeze

**Status: BLOCKED — no final 8,168-drop GDS.**

**Inputs**
- Final ECO GDS after the selected route/fill merge.
- `c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl`
- `build/lvs_chip/rebased_grx930_test_chip.def` (its `DIEAREA` is the die-size authority)
- Final SPEF extracted from the final routed DEF
- PDK deck identities:
  - `c930/asic_gf180mcu/libs.tech/klayout/tech/drc/gf180mcu.drc`
  - `c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs`
  - `c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/metal.rb`
  - `c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/via.rb`
- Constraint source for the 40 ns (`25 MHz`) clock: `i_clk`, input delay 6.0 ns, output delay 6.0 ns, false path on `i_rst_n`.

**Commands**
```bash
cd /c/Users/kubew/grx930
mkdir -p build/production/final build/production/manifests
sha256sum \
  build/production/final/grx930_test_chip_final.gds \
  c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl \
  build/lvs_chip/rebased_grx930_test_chip.def \
  build/production/final/grx930_test_chip.spef \
  c930/asic_gf180mcu/libs.tech/klayout/tech/drc/gf180mcu.drc \
  c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs \
  c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/metal.rb \
  c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/via.rb \
  > build/production/manifests/input_sha256.txt
```

**Frozen input set**
- `build/production/final/grx930_test_chip_final.gds`
- `c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl` (in place; no copy)
- `build/lvs_chip/rebased_grx930_test_chip.def` (in place; no copy; `DIEAREA` is the die authority)
- `build/production/final/grx930_test_chip.spef`
- `build/production/manifests/input_sha256.txt`

**Owner:** Design lead; independent reviewer recomputes hashes.

**Exit criteria**
- One and only one GDS/CDL/DEF/SPEF set is named.
- All four hashes match the recorded manifest.
- `G0_status.txt` has `status=READY_FOR_REVIEW`, `gds_checks=PASS`, `def_gds_checks=PASS`, `no_void=PASS`, and a `manifest_sha256` matching `input_sha256.txt`. `def_gds_checks` XORs the DEF's top-level Metal1–Metal5 routing against the frozen GDS and requires 8,168 approved 2×2 Via1/Via2 placements with none in row 300.
- `G0_signoff.txt` exists with an exact `gate=G0` line, `status=SIGNED`, a non-empty `signed_by`, `signed_utc`, and the same `manifest_sha256`. The canonical fields and empty-value form are in `build/production/manifests/G0_signoff.template.txt`; copy it to `G0_signoff.txt` and fill every field with a **Gridworkz-authorized signatory**. This is a textual owner attestation, not a cryptographic signature, and the agent must not fill it on Gridworkz's behalf.
- GDS top cell is `grx930_test_chip`; **die from DEF `DIEAREA` is 3932 × 5122 µm**. The GDS top-cell bbox must fit inside the die; it is the routed content extent, not the die boundary. The fix16 reference bbox is 3931.530 × 5121.790 µm. The 3930 × 5120 figure in the old submission README is stale and is not the die, core, or boundary-layer definition.
- The GDS includes the 8,168-drop ECO and excludes row 300.
- No VOID submission artifact is used.
- Final CDL is generated from the same netlist as the final DEF.

---

### G1 — DFT/ATPG insertion

**Status: NOT RUN — no scan insertion and no ATPG tool/license.**

**Inputs**
- `c930/asic_gf180mcu/openlane2_design/src/grx930_test_chip_synth_final.v`
- `c930/asic_gf180mcu/gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib`
- `c930/asic_gf180mcu/gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lef/gf180mcu_fd_sc_mcu7t5v0_combined_clean.lef`
- DFT rule deck / scan-cell library from the selected DFT tool
- 8–16 scan chains; full-scan methodology; JTAG/boundary-scan and SRAM BIST requirement from `c930/doc/GRX930_manufacturing_plan.md`

**Commands**
```bash
mkdir -p build/production/dft
# Tool and license must be installed first; the current environment has neither.
command -v dftc
command -v tetramax

dftc -f build/production/dft/dft_insert.tcl \
  > build/production/dft/dft_insert.log 2>&1

# ATPG after scan insertion.
tetramax -shell -f build/production/dft/atpg.tcl \
  > build/production/dft/atpg.log 2>&1
```

The two Tcl files must contain, at minimum:
- scan insertion on every flop, 8–16 chains, scan-in/scan-out/scan-enable/scan-clock ports;
- SRAM BIST insertion for every SRAM instance;
- IEEE 1149.1 boundary scan for all I/O;
- ATPG for stuck-at and transition faults;
- pattern export and a fault-simulation report.

**Output**
- Scan-inserted netlist and scan DEF
- `build/production/dft/dft_insert.log`
- `build/production/dft/scan_report.txt`
- `build/production/dft/atpg.log`
- `build/production/dft/patterns.stil`
- `build/production/dft/fault_coverage.txt`

**Owner:** DFT lead.

**Exit criteria**
- Scan insertion completes with **0 DFT DRC violations**.
- Scan chain count is 8–16; every flop is in exactly one chain; shift-in/shift-out passes.
- SRAM BIST is present for every SRAM instance; boundary scan covers all I/O.
- Stuck-at coverage **≥ 95%**, transition coverage **≥ 90%**, with the uncovered-fault list reviewed.
- ATPG pattern count and fault simulation are retained.
- The scan-inserted netlist and DEF are the inputs to G2. Pre-DFT LVS/DRC/STA results are explicitly marked superseded.

**Open blocker:** `dftc`/`tetramax` are absent from this environment. No DFT or ATPG result is claimed.

---

### G2 — Full-chip LVS

**Status: NOT RUN — no final GDS; prior full run stopped after >100 minutes.**

**Inputs**
- `build/production/final/grx930_test_chip_final.gds`
- `build/production/final/grx930_test_chip.cdl`
- `c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs` (unmodified PDK deck)
- Top cell: `grx930_test_chip`
- 5LM stack

**Command**
```bash
mkdir -p build/production/lvs
docker build -t grx930/klayout-lvs-pmap:local \
  -f build/production/run/Dockerfile.klayout-lvs \
  build/production/run
MSYS_NO_PATHCONV=1 docker run --rm \
  -v C:/Users/kubew/grx930:/work -w /work \
  --entrypoint klayout grx930/klayout-lvs-pmap:local -b \
  -r /work/c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs \
  -rd combine=false \
  -rd check_ports=false \
  -rd top_lvl_pins=true \
  -rd run_mode=tiling \
  -rd verbose=false \
  -rd metal_level=5LM \
  -rd input=/work/build/production/final/grx930_test_chip_final.gds \
  -rd schematic=/work/c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl \
  -rd topcell=grx930_test_chip \
  -rd report=/work/build/production/lvs/report.lvsdb \
  -rd target_netlist=/work/build/production/lvs/extracted.cir \
  > build/production/lvs/lvs.log 2>&1
```

Only the unmodified deck’s documented switches are used: `input`, `schematic`, `topcell`, `report`, `target_netlist`, `combine`, `check_ports`, `top_lvl_pins`, `run_mode`, `metal_level`, and `verbose`. `max_branch_complexity`, `write_netlist`, and `threads` are pruned-deck additions and are deliberately absent.

**G0 precondition:** G2 refuses to run unless G0 is `READY_FOR_REVIEW`, `gds_checks=PASS`, `def_gds_checks=PASS`, `no_void=PASS`, and `G0_signoff.txt` is `SIGNED` with a matching manifest hash. It also recomputes the GDS, SPEF, CDL, and DEF hashes against `input_sha256.txt`; placing or replacing a file without a matching signed G0 cannot start LVS.

**Environment prerequisite:** the unmodified deck calls `pmap` for its memory log line. The stock OpenLane image lacks it. The local image `grx930/klayout-lvs-pmap:local` adds `/usr/local/bin/pmap`, a diagnostic shim that reads resident pages from `/proc/<pid>/statm`; it is intentionally limited to this logging dependency and is not a procps replacement. Do not substitute the pruned deck to work around this.

Do not replace this with `deck_pruned/gf180mcu.lvs` unless the physical-verification lead records a signed deck waiver. The pruned deck is acceptable only as a diagnostic, not as production signoff.

**Output**
- `build/production/lvs/report.lvsdb`
- `build/production/lvs/extracted.cir`
- `build/production/lvs/lvs.log`
- `build/production/lvs/verdict.txt`

**Owner:** Physical verification lead.

**Exit criteria**
- Report contains **0 mismatches**, **0 unresolved nets**, and ends with `Netlists match`.
- Device counts and top-level pin count match the frozen CDL.
- The prior residual of 772 (770 with NWELL taps) is either closed or covered by a numbered, owner-signed waiver; it is not silently accepted.
- Report, log, and extracted netlist hashes are recorded in the gate manifest.
- Full-chip only. Crops and row-level comparisons are evidence for the ECO, not for this gate.

---

### G3 — Full-chip DRC, all decks

**Status: NOT RUN — only focused M1/via checks completed.**

**Inputs**
- `build/production/final/grx930_test_chip_final.gds`
- `c930/asic_gf180mcu/libs.tech/klayout/tech/drc/gf180mcu.drc`
- Variant `gf180mcuD`, 5LM, **all rule decks**
- Top cell `grx930_test_chip`

**Command — complete deck, not a deck filter**
```bash
mkdir -p build/production/drc
MSYS_NO_PATHCONV=1 docker run --rm \
  -v C:/Users/kubew/grx930:/work -w /work \
  --entrypoint klayout ghcr.io/efabless/openlane2:2.3.10 -b \
  -r /work/c930/asic_gf180mcu/libs.tech/klayout/tech/drc/gf180mcu.drc \
  -rd input=/work/build/production/final/grx930_test_chip_final.gds \
  -rd report=/work/build/production/drc/all_decks.lyrdb \
  -rd topcell=grx930_test_chip \
  -rd variant=gf180mcuD \
  -rd metal_level=5LM \
  -rd run_mode=deep \
  -rd threads=8 \
  -rd decks=all \
  > build/production/drc/all_decks.log 2>&1
```

Run an additional **antenna-only** pass if the full-deck log does not identify antenna checks explicitly:
```bash
# Only if the deck's all-deck coverage does not report antenna rules.
MSYS_NO_PATHCONV=1 docker run --rm \
  -v C:/Users/kubew/grx930:/work -w /work \
  --entrypoint klayout ghcr.io/efabless/openlane2:2.3.10 -b \
  -r /work/c930/asic_gf180mcu/libs.tech/klayout/tech/drc/gf180mcu.drc \
  -rd input=/work/build/production/final/grx930_test_chip_final.gds \
  -rd report=/work/build/production/drc/antenna.lyrdb \
  -rd topcell=grx930_test_chip \
  -rd variant=gf180mcuD \
  -rd metal_level=5LM \
  -rd run_mode=deep \
  -rd threads=8 \
  -rd decks=antenna \
  > build/production/drc/antenna.log 2>&1
```

**Output**
- `build/production/drc/all_decks.lyrdb`
- `build/production/drc/all_decks.log`
- Category summary and waiver register
- Separate antenna report if applicable

**Owner:** Physical verification lead.

**Exit criteria**
- Every deck selected by `all` has run to completion; no deck is skipped.
- **0 unwaived findings** across metal, via, FEOL, antenna, density, ERC, well/isolation, latch-up, ESD, sealring, padring, and DFM categories.
- Any waiver has a rule ID, coordinates, justification, owner signature, and foundry acceptance.
- The report includes the complete deck list and the run mode. A metal-only or focused-crop report does not satisfy this gate.

**Open blocker:** The existing fix70 DRC disposition contains 4,318 metal/via findings. That is a baseline classification, not a production-clean result.

---

### G4 — Multi-corner STA and power

**Status: NOT RUN — no final DEF/SPEF, and the existing P&R log ends in DRT-0305.**

**Inputs**
- `build/production/final/grx930_test_chip.def`
- `build/production/final/grx930_test_chip.spef`
- LEF:
  - `c930/asic_gf180mcu/gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lef/gf180mcu_fd_sc_mcu7t5v0.tlef`
  - `c930/asic_gf180mcu/gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lef/gf180mcu_fd_sc_mcu7t5v0_combined_clean.lef`
- Liberty corners under `c930/asic_gf180mcu/gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/`:
  - `gf180mcu_fd_sc_mcu7t5v0__ss_n40C_4v50.lib`
  - `gf180mcu_fd_sc_mcu7t5v0__ss_125C_4v50.lib`
  - `gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib`
  - `gf180mcu_fd_sc_mcu7t5v0__ff_n40C_5v50.lib`
  - `gf180mcu_fd_sc_mcu7t5v0__ff_125C_5v50.lib`
- Clock: `i_clk`, 40.0 ns; input/output delay 6.0 ns; false path `i_rst_n`.

**Command**
```bash
mkdir -p build/production/sta
for corner in ss_n40C_4v50 ss_125C_4v50 tt_025C_5v00 ff_n40C_5v50 ff_125C_5v50; do
  CORNER=$corner openroad -exit build/production/sta/sta_mcorner.tcl \
    > build/production/sta/${corner}.log 2>&1
done
openroad -exit build/production/sta/power_ir.tcl \
  > build/production/sta/power_ir.log 2>&1
```

`sta_mcorner.tcl` must read the LEF, the selected liberty, the frozen DEF, and the frozen SPEF, then apply. The shell exports `CORNER`; the Tcl reads it explicitly:
```tcl
set corner $::env(CORNER)
create_clock -name i_clk -period 40.0 [get_ports i_clk]
set_input_delay  6.0 -clock i_clk [all_inputs]
set_output_delay 6.0 -clock i_clk [all_outputs]
set_false_path -from [get_ports i_rst_n]
report_checks -path_delay max -format full_clock_expanded -group_count 100 \
  > build/production/sta/${corner}_setup.rpt
report_checks -path_delay min -format full_clock_expanded -group_count 100 \
  > build/production/sta/${corner}_hold.rpt
report_power > build/production/sta/${corner}_power.rpt
```

`power_ir.tcl` must run PDN analysis on the frozen DEF:
```tcl
analyze_power_grid -net VDD -corner tt_025C_5v00
check_power_grid -net VDD
analyze_power_grid -net VSS -corner tt_025C_5v00
check_power_grid -net VSS
```

**Output**
- Setup/hold reports for all five corners
- Power report for each corner
- IR/EM reports for VDD and VSS
- Clock/reset integrity report
- Crosstalk and thermal reports from the selected signoff tool

**Owner:** STA/power lead.

**Exit criteria**
- All five corners complete with the same frozen DEF/SPEF.
- **WNS ≥ 0** and **TNS = 0** at every setup corner; **WHS ≥ 0** at every hold corner.
- Max transition, max capacitance, and max fanout: **0 violations**.
- Clock skew, clock latency, and reset recovery/removal are reported and within budget.
- IR drop is within the package/PDN budget; no floating power nets.
- EM limits are met on every power/signal segment.
- Crosstalk and thermal checks are complete or have a signed, numbered waiver.
- Power numbers are reported per corner; no single-corner estimate is labeled full-chip signoff.

**Open blockers:** No SPEF exists, and the current DEF came from an incomplete detailed route (`DRT-0305`). This gate cannot start until G0/G2 produce a routed, extracted database.

---

### G5 — Foundry tape-out review

**Status: NOT RUN — no final GDS/CDL package, no foundry review.**

**Inputs**
- G0 final GDS/CDL/DEF/SPEF
- G2 LVS report and extracted netlist
- G3 full-DRC report and signed waiver register
- G4 STA/power/IR/EM reports
- G1 DFT/ATPG/BIST evidence
- PDK and deck hashes from G0
- Layer map, sealring, padring, pin/pad table, package/pinout
- `c930/asic_gf180mcu/wafer_space_submission/submission_checklist.md`
- `c930/asic_gf180mcu/wafer_space_submission/verify_layers.py`

**Commands**
```bash
mkdir -p build/production/foundry
sha256sum \
  build/production/final/grx930_test_chip_final.gds \
  build/production/final/grx930_test_chip.cdl \
  > build/production/foundry/final_manifest.sha256

python3 c930/asic_gf180mcu/wafer_space_submission/verify_layers.py \
  build/production/final/grx930_test_chip_final.gds \
  > build/production/foundry/layer_check.log 2>&1
```

The foundry review itself is a human signoff. No Gridworkz/wafer.space submission connector exists in this session; do not record a submission that did not happen.

**Output**
- Final GDS/CDL hashes
- Layer/pin/pad/sealring checks
- Signed submission checklist
- Foundry review record and mask-release approval
- Package/pinout approval
- Silicon qualification plan

**Owner:** Tape-out manager; foundry signatory.

**Exit criteria**
- Final GDS/CDL hashes match G0.
- Layer map, top cell, die size, sealring, padring, and pin/pad table are approved.
- LVS, DRC, STA/power, DFT, and test evidence are attached and traceable to the same GDS.
- Every DRC/LVS waiver is numbered and foundry-accepted.
- Mask preparation and package/pinout are approved.
- Silicon qualification/corner plan is approved.
- Foundry signs the tape-out review. **No foundry submission is claimed until a receipt exists.**

## 5. Evidence and release rule

Every gate writes:

```
build/production/<gate>/
  command.txt
  input_sha256.txt
  <report>
  <log>
  verdict.txt
  owner_signoff.txt
```

`verdict.txt` starts as `NOT RUN`. It may be changed to `PASS` only by the named owner after the exit criteria are checked. A report without a signoff is evidence, not a gate pass.

**Release status: NOT APPROVED.** G0 through G5 are **NOT RUN** or **BLOCKED** as stated above. The focused 13-site crop at `build/lvs_chip/eco_drop_2x2/row_corrected/` is **not** an input to any production gate except as ECO-geometry evidence.
