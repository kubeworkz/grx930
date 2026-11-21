# Production signoff plan — GRX930 test chip

**Status: NOT RUN. No production gate is complete.**
This plan is a sequence and evidence contract, not a result. A gate is complete only when its command has run on the frozen input, its full report is retained, its hash is recorded, and the named owner has signed the exit criteria.

## 1. Current facts that gate the plan

| Fact | Current state |
|---|---|
| Final merged GDS | **Present as the Stage 7 stream.** `build/production/final/grx930_test_chip_final.gds` is the G0 GDS (154,570,546 bytes; SHA-256 `8fdeb5812ae7325a0b336e26b60cb873e1c75d370640aa63ecd69b0acf766b62`), streamed from `eco_routed.def`. The 8,168-drop `fix70` GDS is still absent. `c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds` is explicitly marked **VOID** in its README and is not an input. |
| Final schematic/CDL | `c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl` exists (17,754,516 bytes; SHA-256 `1a29a6ad2cb99882a8e2d8974cadff3237f317cc349c1a0c3e7f20545f75b717`) and is frozen in place by G0. |
| Final routed DEF | `build/lvs_chip/eco_drop_2x2/stage6/eco_routed.def` is the G0 DEF (172,217,358 bytes; SHA-256 `d8c7211bf6d20db3297395d5a5c6ff5f31e9df70e3cb9ef55b6ef6b525579a01`; 168 Via1/Via2 ECO drops). It was built from `filled.def`, not from the pre-ECO `rebased_grx930_test_chip.def`; the rebased DEF has `SPECIALNETS 4` and 0 ECO vias and cannot pair with the ECO GDS. |
| Final SPEF | **Present.** `build/production/final/grx930_test_chip.spef` is 188,709,802 bytes, SHA-256 `f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0`, extracted from `eco_routed.odb` with the pinned OpenROAD `dcf36133` nom RCX model. G0 reads it as a required input. |
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

**Status: READY_FOR_REVIEW — all inputs are present and both geometry checks pass; no signoff exists.**

The 2026-11-21T21:39:35Z run wrote `status=READY_FOR_REVIEW`,
`gds_checks=PASS`, `def_gds_checks=PASS`, `no_void=PASS`, `missing=none`,
`failures=none`,
`manifest_sha256=15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800`,
and exited 0. G0 is still not signed: `G0_signoff.txt` is absent, so this is
evidence for the design lead and independent reviewer, not a gate pass.

**Inputs**
- Final ECO GDS: `build/production/final/grx930_test_chip_final.gds`, streamed from `eco_routed.def`.
- Pre-ECO base GDS: `build/production/final/pre_eco_stream.gds`, streamed from `filled.def`. The base/final GDS delta is exactly the inserted ECO.
- `c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl`
- `build/lvs_chip/eco_drop_2x2/stage6/eco_routed.def` (the final routed DEF; its `DIEAREA` is the die-size authority)
- `build/lvs_chip/eco_drop_2x2/stage6/filled.def` (the pre-ECO DEF the ECO was inserted into)
- `build/lvs_chip/eco_drop_2x2/stage6/eco_sites_v3.csv` (the frozen 168-site list)
- Final SPEF extracted from the final routed DEF: `build/production/final/grx930_test_chip.spef`
- `build/production/run/gds_checks.rb` and `build/production/run/def_gds_checks.rb`
- PDK deck identities:
  - `c930/asic_gf180mcu/libs.tech/klayout/tech/drc/gf180mcu.drc`
  - `c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs`
  - `c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/metal.rb`
  - `c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/via.rb`
- Constraint source for the 40 ns (`25 MHz`) clock: `i_clk`, input delay 6.0 ns, output delay 6.0 ns, false path on `i_rst_n`.

**Commands**
```bash
cd /c/Users/kubew/grx930
EXPECTED_DROPS=168 EXPECTED_DIE_W=3932 EXPECTED_DIE_H=5122 \
  bash build/production/run/g0_freeze.sh
```

The script refuses with exit 2 if `EXPECTED_DROPS`, `EXPECTED_DIE_W` or
`EXPECTED_DIE_H` is unset; none has a default. It writes
`build/production/manifests/input_sha256.txt` itself, recording `MISSING <path>`
for any absent input, then runs `gds_checks.rb` and `def_gds_checks.rb` in the
OpenLane KLayout image and writes `G0_status.txt`. It passes `-rd base`,
`-rd base_def` and `-rd sites` to `def_gds_checks.rb`, so the per-window delta
check is part of the gate rather than an optional extra. Recompute the recorded
hashes with:

```bash
sha256sum -c build/production/manifests/input_sha256.txt
```

A `MISSING` line is not a checksum line, so `sha256sum -c` exits non-zero on it;
that is the intended reminder that the input set is incomplete.

**Frozen input set (2026-11-21 values; `input_sha256.txt` is authoritative)**

| Input | SHA-256 |
|---|---|
| `build/production/final/grx930_test_chip_final.gds` | `8fdeb5812ae7325a0b336e26b60cb873e1c75d370640aa63ecd69b0acf766b62` |
| `build/production/final/pre_eco_stream.gds` | `dcdd8a307f53e7f298940a49b555b6a8037ad2aaad145ce45e08ba0923a29b04` |
| `c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl` | `1a29a6ad2cb99882a8e2d8974cadff3237f317cc349c1a0c3e7f20545f75b717` |
| `build/lvs_chip/eco_drop_2x2/stage6/eco_routed.def` | `d8c7211bf6d20db3297395d5a5c6ff5f31e9df70e3cb9ef55b6ef6b525579a01` |
| `build/lvs_chip/eco_drop_2x2/stage6/filled.def` | `2ae87c2db7a0f6a1bb0095ee9f9a8a2786a556d07eb49208640ba772ef1fac04` |
| `build/lvs_chip/eco_drop_2x2/stage6/eco_sites_v3.csv` | `8efedede2176095d20b634a04c16f1ffd1d7f8cdc8edcd0025b1e60b6ee01c82` |
| `build/production/final/grx930_test_chip.spef` | `f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0` |
| `build/production/run/gds_checks.rb` | `fbfac9851f7b6209ae086b27ebd9bc9f9928cd2ce87e2d69d93253e8d616bac5` |
| `build/production/run/def_gds_checks.rb` | `55945b780991609e392721164efabac477c23918324f171f7b44e49dae54eb93` |
| `gf180mcu.drc` | `e7c7d2597890cfcb4cf0e5312f5652051a119fb3e1cc1772a6e5c04594bc65d8` |
| `gf180mcu.lvs` | `00019ed0a7f434fc9ead466be75c07cbaed4bf5de698446d6e3fafd43ac7cc59` |
| `metal.rb` | `d8ba81b38adc8258c867c87a11a653640ad62b78ea61e7de3729b57bea2aee1e` |
| `via.rb` | `d48ead7abee03dec2bf9eb0abbf343c407dc4f1fc2e71b30878d38639ecaf5bf` |

`input_sha256.txt` records the full path of every entry; the last four rows are
the PDK deck files listed under **Inputs**. The CDL and both DEFs are used in
place; no copies are accepted as substitutes.

**SPEF extraction record (2026-11-21)**
- Tool: OpenROAD `dcf36133a369abc8f3c5e5738cd4d82e4903c0e0` from `ghcr.io/wafer-space/gf180mcu-precheck:104d9ccbc0d3`.
- Model: GF180MCU `nom` RCX rules, `/workspace/gf180mcu/gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD.nom`, SHA-256 `d83a04ea28af9b74a097fb479bbab9ed52859a1e3428b33d3151cb5afae62ddf`.
- Database: `build/lvs_chip/eco_drop_2x2/stage6/eco_routed.odb` (206,880,759 bytes; `sub` special net, 1 swire, 504 sboxes).
- Command:
```tcl
read_db /work/build/lvs_chip/eco_drop_2x2/stage6/eco_routed.odb
extract_parasitics -ext_model_file /workspace/gf180mcu/gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD.nom
write_spef /work/build/production/final/grx930_test_chip.spef
```
`define_process_corner` alone left the model filename empty in this build (`RCX-0468`); the single-corner `-ext_model_file` form loaded the same model and defined `MinMax0`.
- Output: 188,709,802 bytes, SHA-256 `f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0`; `*DESIGN "grx930_test_chip"`, `*VERSION "dcf36133..."`, 125,214 `*D_NET`s; extraction ended `RCX_DONE`, exit 0.
- Coverage: 126,236 DEF signal nets, of which 1,022 have fewer than two terminals and no wire; 126,236 − 1,022 = 125,214 annotated nets. `read_spef` reported 0 unannotated drivers and 0 partially unannotated drivers.

**Owner:** Design lead; independent reviewer recomputes hashes.

**Exit criteria**
- One and only one GDS/CDL/DEF/SPEF set is named, and it is the set above. The pre-ECO `rebased_grx930_test_chip.def` and the fix16 base are not G0 inputs.
- Every entry in `input_sha256.txt` matches its named file and no entry is `MISSING`.
- `G0_status.txt` has `status=READY_FOR_REVIEW`, `gds_checks=PASS`, `def_gds_checks=PASS`, `no_void=PASS`, and a `manifest_sha256` matching `input_sha256.txt`. The current run is `READY_FOR_REVIEW` with `missing=none` and `failures=none`; it is not signed.
- `gds_checks.rb` requires `expected_drops` and reports `DROPS=168`, `VIA2_NEW_CUTS=672`, `DEF_DIE_UM=3932.000x5122.000` and `FAILURES=`; the GDS content bbox is inside the DEF die.
- `def_gds_checks.rb` XORs the DEF's top-level Metal1–Metal5 routing against the final GDS and requires 168 approved 2×2 Via1/Via2 placements. With `-rd base=pre_eco_stream.gds -rd base_def=filled.def -rd sites=eco_sites_v3.csv` it also compares `(final.gds − base.gds)` against `(eco_routed.def − filled.def)` inside each site window and requires zero new metal or Via1/Via2 cut outside the windows. On the current pair: 168/168 windows PASS, `WINDOWS_WITH_DELTA=168`, `WINDOW_FAILURES=0`, and every `OUTSIDE_WINDOWS_*_DBU2=0`. VDD exclusion is expressed in `eco_sites_v3.csv`; the retired fixed row-300 box is not part of the check.
- `def_gds_checks.rb` has a positive control: `build/production/run/test_def_gds_positive.sh` generates a synthetic 8,168-site DEF/GDS pair in `build/production/fixtures/def_gds_positive/` and requires zero XOR on Metal1–Metal5 and exactly 8,168 Via1/Via2 2×2 placements. At every DEF via anchor it XORs the 0.26 µm 2×2 cut array against GDS Via1 35/0 and Via2 38/0 (32,672 cut shapes per layer). The harness requires a second GDS with two omitted cut arrays to fail, a windowed positive whose base/final pair must report 8,168/8,168 clean, non-empty windows with no delta outside them, and the same pair with one site moved +5 µm to fail with one empty window and outside-window geometry. The pairs are synthetic; the fixture's 8,168-site count is a control independent of the production count, which is 168, and it does not substitute for the production ECO, whose full 8,168-coordinate list is absent from this checkout.
- `G0_signoff.txt` exists with an exact `gate=G0` line, `status=SIGNED`, a non-empty `signed_by`, `signed_utc`, and the same `manifest_sha256`. The canonical fields and empty-value form are in `build/production/manifests/G0_signoff.template.txt`; copy it to `G0_signoff.txt` and fill every field with a **Gridworkz-authorized signatory**. This is a textual owner attestation, not a cryptographic signature, and the agent must not fill it on Gridworkz's behalf.
- GDS top cell is `grx930_test_chip`; **die from DEF `DIEAREA` is 3932 × 5122 µm**. The GDS top-cell bbox must fit inside the die; it is the routed content extent, not the die boundary. The Stage 7 GDS content bbox is 3931.530 × 5121.790 µm at (0.090, 0.090), inside the die. The 3930 × 5120 figure in the old submission README is stale and is not the die, core, or boundary-layer definition.
- The GDS includes the 168-drop ECO from `eco_sites_v3.csv`; the site list already excludes VDD, so no separate row-300 exclusion is asserted.
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

**Status: NOT RUN — G0 is unsigned; prior full run stopped after >100 minutes.**

**Inputs**
- `build/production/final/grx930_test_chip_final.gds`
- `c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl` (the G0-frozen CDL, in place; no copy)
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

**Status: NOT RUN — G0 is unsigned; the DEF and SPEF are the frozen Stage 7 pair.**

**Inputs**
- `build/lvs_chip/eco_drop_2x2/stage6/eco_routed.def` (the G0-frozen DEF; no copy)
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
build/production/run/g4_sta.sh
```

`g4_sta.sh` runs the five corners through `sta_mcorner.tcl` and then runs `power_ir.tcl`. It supplies `CORNER`, the frozen `DEF`, and the frozen `SPEF` to both helpers; direct invocation requires those environment variables. `sta_mcorner.tcl` must read the LEF, the selected liberty, the frozen DEF, and the frozen SPEF, then apply:
```tcl
set corner $::env(CORNER)
set def $::env(DEF)
set spef $::env(SPEF)
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

**Open blockers:** The DEF and SPEF are the G0-frozen `eco_routed.def` and `grx930_test_chip.spef`; the old incomplete-route `rebased_grx930_test_chip.def` is not an input. This gate cannot start until G0 is signed; no multi-corner STA/power run has been made.

---

### G5 — Foundry tape-out review

**Status: NOT RUN — no signed G0 package, no foundry review.**

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
  c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl \
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

**Release status: NOT APPROVED.** G0 is **READY_FOR_REVIEW** but unsigned; G1–G5 are **NOT RUN** or **BLOCKED** as stated above. The focused 13-site crop at `build/lvs_chip/eco_drop_2x2/row_corrected/` is **not** an input to any production gate except as ECO-geometry evidence.

## 6. Limit closure register

A full-depth workspace search, `git rev-list --all --objects`, and `git lfs ls-files` found none of the still-missing inputs below; the local OpenLane run trees contain only lint stages. The Stage 7 GDS pair is present and hashed in G0. These limits cannot be closed by changing the checker.

| Limit | Current evidence | Closure input |
|---|---|---|
| Real 8,168-drop coordinate list | `validate_drop_windows_2x2.rb` needs `c930/asic_gf180mcu/build/lvs_chip/fill_regression_tie_final.gds` and `/scripts/chip.l2n`; both absent. Selected `fix70` GDS (`c5fa46ed3d17e36b75026964655e6376d15a00ca03f57f67277290fc98c20738`) and accepted `fix59` base (`3f82dff9090c2c5d7a3fe7c921db3dd3dbc4ecda37b21f5d28c754abcff2bdae`) absent. | Supply those sources, or authorize a new 541-row extraction from a named baseline. |
| Final GDS | Present as the Stage 7 168-drop stream; hashed in `input_sha256.txt` and checked by `gds_checks.rb` and `def_gds_checks.rb`. The 8,168-drop `fix70` GDS is still absent. | Nothing for the 168-drop G0 GDS; the 8,168 identity needs the old database. |
| Final SPEF | Present: 188,709,802 bytes, SHA-256 `f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0`; extracted from the Stage 7 `eco_routed.odb` with OpenROAD `dcf36133` nom RCX and read back with 0 unannotated drivers. | None for G0; the signoff corners may still require their own extraction runs. |
| Gridworkz G0 signoff | No `G0_signoff.txt`; no Gridworkz connector/API. | Gridworkz-authorized signature over the frozen manifest. |

Real-pair probes are not substitutes. `stream_out_filled.gds` against `filled/grx930_test_chip_filled.def` gives Metal1 XOR 0 but Metal2–Metal5 XOR 117,600 / 1,303,157,600 / 665,639,200 / 13,321,905,600 dbu²; `stream_out.gds` against the September `grx930_test_chip.def` gives the same numbers. Shape counts match per layer, but the local DEFs and streamed GDS files are not from the same stream-out revision, so neither pair is a zero-XOR real control. The synthetic fixtures remain the only passing controls.

Until the remaining inputs above arrive and G0 is signed, G2 and G4 stay blocked and the package stays **VOID — DO NOT SUBMIT**.
