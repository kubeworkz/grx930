# pdn_cfg_grx930_sram.tcl -- pdn_cfg_grx930.tcl plus macro grids for the eight
# byte-sliced SRAM macros of the macro-flow surrogate (scope §7 step 3).
#
# pdn_cfg_grx930.tcl is the template's PDN with its SRAM stripe block removed,
# because the routing part had no macro. The surrogate has eight, and a macro
# whose VDD/VSS are not strapped is disconnected from the grid -- so this file
# sources that one unchanged and then adds the per-instance grids.
#
# The numbers are the template's own (pdn/pdn_5v_sram.tcl), which were tuned for
# this macro: Metal4 straps on the W/E edges at the macro's width, then a second
# set to bridge over them, because the edge straps cut the top-level Metal4 grid.
# The template defines one grid per instance for the same reason, so this loops
# over the eight slices rather than claiming them in one grid.

if {![info exists ::env(DESIGN_DIR)]} {
    throw APPLICATION "pdn_cfg_grx930_sram.tcl needs DESIGN_DIR to find pdn_cfg_grx930.tcl"
}

source $::env(DESIGN_DIR)/pdn/pdn_cfg_grx930.tcl

foreach i {0 1 2 3 4 5 6 7} {
    define_pdn_grid \
        -macro \
        -instances "i_chip_core.u_core.u_sram.u_macro_$i" \
        -name "sram_macro_$i" \
        -starts_with POWER \
        -halo "$::env(PDN_HORIZONTAL_HALO) $::env(PDN_VERTICAL_HALO)"

    add_pdn_connect \
        -grid "sram_macro_$i" \
        -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"

    add_pdn_connect \
        -grid "sram_macro_$i" \
        -layers "$::env(PDN_VERTICAL_LAYER) Metal3"

    # Straps on the W/E edges of the macro.
    add_pdn_stripe \
        -grid "sram_macro_$i" \
        -layer Metal4 \
        -width 2.36 \
        -offset 1.18 \
        -spacing 0.28 \
        -pitch 426.86 \
        -starts_with GROUND \
        -number_of_straps 2

    # The edge straps block the top-level grid at Metal4, so add the bridge set.
    add_pdn_stripe \
        -grid "sram_macro_$i" \
        -layer Metal4 \
        -width 4.00 \
        -offset 65.93 \
        -spacing 0.28 \
        -pitch 50 \
        -starts_with GROUND \
        -number_of_straps 7
}
