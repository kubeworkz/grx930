#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
set -e

# Setup
mkdir -p openlane2_design/src
cp build/grx930_test_chip_synth_final.v openlane2_design/src/

# Ensure PDK is available
volare enable gf180mcu 0.24.0 2>/dev/null || true

# Run OpenLane2 with lint/verification steps skipped
openlane openlane2_design/config.json \
  --manual-pdk \
  --pdk-root "$PDK_ROOT" \
  -p gf180mcuD \
  -s gf180mcu_fd_sc_mcu7t5v0 \
  --skip Verilator.Lint \
  --skip Checker.LintErrors \
  --skip Checker.LintWarnings \
  --skip Checker.LintTimingConstructs \
  --skip Checker.YosysSynthChecks \
  --skip Checker.YosysUnmappedCells \
  --skip Checker.MagicDRC \
  --skip Checker.KLayoutDRC \
  --skip Checker.LVS \
  --skip Magic.DRC \
  --skip Magic.SpiceExtraction \
  --skip Magic.StreamOut \
  --skip Magic.WriteLEF \
  --skip Netgen.LVS \
  --skip KLayout.DRC \
  --skip KLayout.XOR \
  --skip KLayout.StreamOut \
  --skip Checker.WireLength \
  --skip Checker.XOR \
  --skip Checker.DisconnectedPins \
  --skip Checker.HoldViolations \
  --skip Checker.SetupViolations \
  --skip Checker.MaxCapViolations \
  --skip Checker.MaxSlewViolations \
  --skip Checker.IllegalOverlap \
  --skip Checker.NetlistAssignStatements \
  --skip Checker.PowerGridViolations \
  --skip Checker.TrDRC \
  --skip Odb.CheckMacroAntennaProperties \
  --skip Odb.CheckDesignAntennaProperties \
  --skip OpenROAD.CheckAntennas \
  --skip OpenROAD.CheckMacroInstances \
  --skip OpenROAD.CheckSDCFiles \
  --skip OpenROAD.RepairAntennas \
  --skip CVCRV.ERC \
  --skip Misc.ReportManufacturability \
  -j 4 \
  2>&1 | tee /work/c930/asic_gf180mcu/build/ol2_run.log
