# Copyright 2020-2022 Efabless Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# PATCHED (recovery from DPL-0036 in OpenROAD.RepairAntennas, Sep 2026):
#  1. Reuse the global route guides persisted in the input ODB instead of
#     unconditionally re-running global_route first (~10h saved). Falls back
#     to the original full global_route if no routes are found.
#  2. repair_antennas() internally re-legalizes inserted diodes with a
#     hardcoded 500-site x 100-row window and raises DPL-0036 when some
#     instances cannot be placed. Catch that error so the script continues:
#     dpl.tcl below re-runs detailed_placement with PL_MAX_DISPLACEMENT_X/Y,
#     which is large enough for this design (proven in step 33).

source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
read_current_odb
source $::env(SCRIPTS_DIR)/openroad/common/dpl_cell_pad.tcl

set_propagated_clock [all_clocks]

if { [grt::have_routes] || [grt::have_detailed_routes] } {
    puts "PATCH: reusing global routes/guides from ODB; skipping redundant initial global_route."
    source $::env(SCRIPTS_DIR)/openroad/common/set_routing_layers.tcl
    source $::env(SCRIPTS_DIR)/openroad/common/set_layer_adjustments.tcl
    set_macro_extension $::env(GRT_MACRO_EXTENSION)
    set ::grt_preamble 1
} else {
    puts "PATCH: no routes found in ODB; running full global_route (original behavior)."
    source $::env(SCRIPTS_DIR)/openroad/common/grt.tcl
}

set diode_split [split $::env(DIODE_CELL) "/"]
if { [catch {repair_antennas "[lindex $diode_split 0]" -iterations $::env(GRT_ANTENNA_ITERS) -ratio_margin $::env(GRT_ANTENNA_MARGIN)} err] } {
    puts "PATCH WARNING: repair_antennas failed: $err"
    puts "PATCH WARNING: clearing FIRM placement status left behind, then continuing;"
    puts "PATCH WARNING: dpl.tcl will re-legalize the design with PL_MAX_DISPLACEMENT."
    set blk [ord::get_db_block]
    foreach inst [$blk getInsts] {
        if { [string equal [$inst getPlacementStatus] "FIRM"] } {
            $inst setPlacementStatus PLACED
        }
    }
}

source $::env(SCRIPTS_DIR)/openroad/common/dpl.tcl
# PATCH v2: the post-dpl full global_route (original line 26) was REMOVED.
# Running it in the same process as repair_antennas grew past 19 GB and was
# OOM-killed on this 15 GiB host. Guides covering the inserted diodes and
# re-legalized cells are regenerated instead by a separate standalone
# OpenROAD.GlobalRouting step (fresh process) run after this step completes.

source $::env(SCRIPTS_DIR)/openroad/common/set_rc.tcl
estimate_parasitics -global_routing

write_views
