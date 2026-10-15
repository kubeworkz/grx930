# wafer.space GF180MCU submission — state of play

> **Superseded as a status document, kept as the process checklist.** The September GDS in
> `wafer_space_submission/` is **void** (see its `SUPERSEDED.md`: pre-fix RTL, SRAM
> optimised away, no CTS). The replacement is a full LibreLane run of the wafer.space
> project template with the core inside it — see
> [`wafer_space_integration/README.md`](wafer_space_integration/README.md) and
> `Claude outputs/tapeout_gds_plan.md`. This file lists what the *submission* has to
> satisfy; the boxes stay empty until the pre-check has been run on the final GDS.

## Quick Reference

| Item | Value |
|------|-------|
| **Slot** | 1×1 (full) |
| **Die size** | 3932 × 5122 µm (`librelane/slots/slot_1x1.yaml`) |
| **Core area** | 442 442 3490 4680 µm = 12.93 mm² |
| **Pad ring** | template default: 18 power pads + 12 inputs + 40 bidir + 2 analog + clk + rst_n |
| **Deadline** | 16 December 2026 (GDS submission) |

## What the pre-check actually enforces

From [gf180mcu-precheck](https://github.com/wafer-space/gf180mcu-precheck) (`precheck.py`):

- [ ] one top-level cell in the GDS, matching `--top`
- [ ] origin (0,0), dbu 0.001 µm
- [ ] max metal layer **Metal5**
- [ ] die dimensions match the selected slot
- [ ] CoB cells (`gf180mcu_ws_ip__qrcode_id`, `__shuttle_id`, `__project_id`, `__marker`)
      present exactly once, at the template's locations — *only with `--cob`*
- [ ] pad openings match the slot's pad mask
- [ ] density check
- [ ] no zero-area polygons
- [ ] KLayout antenna check
- [ ] magic DRC
- [ ] KLayout DRC

Note the tool imports `librelane.steps.klayout`, so it needs a **LibreLane ≥ 3**
environment (nix install per their README, or the LibreLane image) — not the OpenLane2
2.3.10 image the OL2/core investigation uses.

## What the chip side already guarantees

- [x] **the part boots standalone**: boot ROM at `0x0001_0000` = `CORE_RESET_PC`,
      `make sim SIM_PLUSARGS=+NO_PRELOAD` passes, `-DROM_DISABLE` control fails
      (`README.md`, `PLAN_B_netlist_rework.md` §8)
- [x] **pad ring compatibility by construction**: the template's `chip_top.sv` and
      `slot_1x1.yaml` are used unmodified, so pad positions/count and the marker cells are
      the standard 1×1 set (`wafer_space_integration/PAD_MAP.md`)
- [x] **adapter checked**: `sh wafer_space_integration/run_adapter_lint.sh`

## Still to do (in order)

- [ ] settle the flow engine for the template run (OpenLane2 2.3.10 vs LibreLane 3 image),
      then stage `wafer_space_integration/` into `ws/template/` on the flow box
- [ ] pick the routing configuration from the OL2 fast-DRT arm (GRT adjustment / bottom
      layer) and run the **full template flow from a fresh run tag** (a resumed tag reuses
      its netlist; the RTL has changed since — caches, MMIO hold, boot ROM)
- [ ] run the pre-check on the resulting `chip_top.gds` and fix findings
- [ ] package for submission: GDS, gate-level netlist, SPEF, the DRC/LVS reports the
      pre-check produced, and a README describing the part

## Contact

- **wafer.space**: https://wafer.space · Discord: https://discord.gg/wafer-space
- **Pre-check repo**: https://github.com/wafer-space/gf180mcu-precheck
- **Project template**: https://github.com/wafer-space/gf180mcu-project-template
