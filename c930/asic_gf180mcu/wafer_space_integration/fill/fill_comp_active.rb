# Dummy COMP fill for the wafer.space 1x1 template.
#
# Copied from the GF180MCU PDK's libs.tech/klayout/tech/scripts/fill_comp.rb (Apache-2.0,
# Copyright 2022 GlobalFoundries PDK Authors) with two changes, both marked below and both
# measured rather than assumed. See README.md in this directory.
#
#   CHANGE_1  the COMP exclusion halo is $comp_halo_um (default 0) instead of a fixed 10 um --
#             on this die the foundry's 13.5 um keeps dummy COMP out of the whole core.
#   CHANGE_2  the fill pattern is $fill_um x $fill_um on $line_space_um (defaults 6.0 / 2.0)
#             instead of 5x5 on 3.0, and the stagger is derived from the space rather than copied.
#
# The pattern cell is named COMP_fill_cell -- the foundry's own name, and the one the
# wafer.space pre-check's magic step flattens by name to avoid false positives on dummy fill
# (precheck.py MAGIC_GDS_FLATGLOB: "COMP_FILL", "COMP_fill_cell", "POLY2_FILL",
# "Poly2_fill_cell"). Do not rename it: a wildcard is not used there, so a variant name would
# silently fall out of that list.
#
# A third change -- a second pass with a 3 um cell, restricted to the zone where the Poly2 step
# could pair a dummy Poly2 with the dummy COMP -- was measured and removed. It added 8,253 um^2
# of dummy COMP (0.04 % of the die, 3,070,548 -> 3,078,801 um^2, fillrun/twopass.log) for a
# second full tiling pass over the 20.1 mm^2 die: the first pass already tiles its own legal
# region at the checked 1.9 um spacing, so the 2.5 um gaps it leaves cannot hold a 3 um square
# that must stay 1.9 um away from it. What that pass was for -- the pairing zone -- is now the
# Poly2 step's business, not the COMP step's: see fill_poly2_active.rb.
#
# The rules the fill must keep (DCF.4 3.5 um to COMP, DCF.2b 1.9 um between dummy COMP, DCF.5
# 1.5 um to Poly2, plus the DCF.6/7a/8a/9/11a/12 exclusions) are the foundry script's, unchanged.

# --- CHANGE_1 ---------------------------------------------------------------------------------
# The foundry script grows COMP by 10 um before adding the DCF.4 spacing, i.e. it keeps dummy
# COMP 13.5 um from circuit COMP. That 10 um is the manual's DCF.1a guideline, which the
# gf180mcuD deck does not check; the checked rule is DCF.4 = 3.5 um.
$comp_halo_um = ($comp_halo_um || 0.0).to_f

# --- CHANGE_2 ---------------------------------------------------------------------------------
# The foundry's 5x5 on 3 um pattern (DCF.1c / DCF.2a in the manual, neither checked by the deck)
# covers 40.7 % of its region and cannot carry both density floors on this die.
fill_size  = ($fill_um || 6.0).to_f
line_space = ($line_space_um || 2.0).to_f

# The stagger, and why it is not the foundry's 1.6 um.
#
# The lattice steps are (fill+space, stagger) and (stagger, fill+space). Two squares that are
# i=1,j=0 apart sit exactly `line_space` apart along x; two that are i=1,j=1 apart are the
# diagonal pair, and their corner-to-corner distance is (line_space - stagger) * sqrt(2). So the
# pattern's own minimum dummy COMP space is
#
#   min(line_space, |line_space - stagger| * sqrt(2))
#
# and DCF.2b -- a rule the deck DOES check -- wants 1.9 um between dummy active in all directions.
# The foundry's 5x5 on 3.0 with the 1.6 stagger passes because (3.0-1.6)*sqrt(2) = 1.98; carrying
# that same 1.6 stagger onto a 1.9 um space gives (1.9-1.6)*sqrt(2) = 0.42 um, and the deck
# reports it as 42,688 DCF.2b violations over this die (measured; the axial 1.9 um is not enough
# on its own). 0.5 satisfies |2.0-0.5|*sqrt(2) = 2.12 >= 2.0, i.e. the diagonal is no longer the
# binding pair, and the checked value keeps 0.1 um of margin instead of sitting on the rule.
STAGGER_UM = 0.5
DCF2B_UM = 1.9

if line_space < DCF2B_UM || (line_space - STAGGER_UM).abs * Math.sqrt(2) < DCF2B_UM
  $stderr.puts format("WARNING: this pattern's minimum dummy COMP space is %.3f um, below the " \
                      "checked DCF.2b value of %.1f um -- the deck will flag it",
                      [line_space, (line_space - STAGGER_UM).abs * Math.sqrt(2)].min, DCF2B_UM)
end

fc_origin = RBA::DPoint::new(0.0, 0.0)

fill_patch_cell = lambda do |name, size|
  cell = $ly.cell(name)
  if ! cell
    cell = $ly.create_cell(name)
    cell.shapes(COMP_Dummy).insert($micron2dbu * RBA::DBox::new(-size / 2, -size / 2, size / 2, size / 2))
  end
  cell
end

# ----------------------------
# implementation

fc_name = "COMP_fill_cell"

fill_cell = fill_patch_cell.call(fc_name, fill_size)

fc_box_in_dbu = $micron2dbu * RBA::DBox::new(-fill_size / 2, -fill_size / 2, fill_size / 2, fill_size / 2)
fc_origin_in_dbu = $micron2dbu * fc_origin

# DCF.2a / DCF.3 lattices (the resulting space is the line space, DCF.2b's checked value; see
# STAGGER_UM above for what the second component may be).
row_step = RBA::DVector::new(fill_size + line_space, STAGGER_UM)
column_step = RBA::DVector::new(STAGGER_UM, fill_size + line_space)

row_step_in_dbu    = $micron2dbu * row_step
column_step_in_dbu = $micron2dbu * column_step

tp = RBA::TilingProcessor::new
tp.frame = $chip
tp.dbu = $ly.dbu
tp.threads = $threads
tp.tile_size(400, 400)
# Find optimal value?
tp.tile_border(30, 30)

tp.input("COMP", $ly, $top_cell.cell_index, COMP)
tp.input("Poly2", $ly, $top_cell.cell_index, Poly2)
tp.input("NDMY", $ly, $top_cell.cell_index, NDMY)
tp.input("PMNDMY", $ly, $top_cell.cell_index, PMNDMY)
tp.input("MTPMK", $ly, $top_cell.cell_index, MTPMK)

tp.input("Nwell", $ly, $top_cell.cell_index, Nwell)
tp.input("DNWELL", $ly, $top_cell.cell_index, DNWELL)
tp.input("LVPWELL", $ly, $top_cell.cell_index, LVPWELL)
tp.input("Dualgate", $ly, $top_cell.cell_index, Dualgate)

tp.input("RES_MK", $ly, $top_cell.cell_index, RES_MK)
tp.input("Pad", $ly, $top_cell.cell_index, Pad)
tp.input("IND_MK", $ly, $top_cell.cell_index, IND_MK)

tp.var("line_space", line_space / $ly.dbu)

# CHANGE_1: comp_halo replaces the hard-coded 10 um
tp.var("comp_halo", $comp_halo_um / $ly.dbu)

# DPF.1
# Make sure to exclude some space at the tile border
# to ensure there will be no dummy poly2 without a
# dummy comp
tp.var("Poly2_extension", 0.3 / $ly.dbu)

# DCF.4
tp.var("space_to_COMP", 3.5 / $ly.dbu)
# DCF.5
tp.var("space_to_Poly2", 1.5 / $ly.dbu)

# DCF.6abcd
tp.var("space_to_Nwell", 1.3 / $ly.dbu)
tp.var("space_to_DNWELL", 4 / $ly.dbu)
tp.var("space_to_LVPWELL", 1.3 / $ly.dbu)
tp.var("space_to_Dualgate", 1.3 / $ly.dbu)

# DCF.7a
tp.var("space_to_scribe_line", 26 / $ly.dbu)

# DCF.8a
tp.var("space_to_RES_MK", 3.5 / $ly.dbu)

# DCF.9
tp.var("space_to_Pad", 7 / $ly.dbu)

# DCF.11a
tp.var("space_to_NDMY", 3.5 / $ly.dbu)

# DCF.12
tp.var("space_to_IND_MK", 3.0 / $ly.dbu)

tp.var("um1", 1 / $ly.dbu)
tp.var("um2", 2 / $ly.dbu)
tp.var("um20", 20 / $ly.dbu)
tp.var("um10", 10 / $ly.dbu)

printf("  pattern: %s = %.1f x %.1f um, stagger %.1f um, minimum dummy COMP space %.3f um (DCF.2b wants %.1f)\n",
       fc_name, fill_size, fill_size, STAGGER_UM,
       [line_space, (line_space - STAGGER_UM).abs * Math.sqrt(2)].min, DCF2B_UM)

tp.output("to_fill", TilingOperator::new($ly, $fill_cell_comp, fill_cell.cell_index, fc_box_in_dbu,
                                        row_step_in_dbu, column_step_in_dbu, fc_origin_in_dbu))

# perform the computations inside the tiling processor through "expression" syntax
# (see https://www.klayout.de/doc-qt4/about/expressions.html)
tp.queue("

# DCF.1a - use octagon_limit for sizing, do multiple steps for better performance
# CHANGE_1: comp_halo replaces the hard-coded um10
var COMP_spacing = COMP.sized(comp_halo, 0, mode=2).sized(0, comp_halo, mode=2).sized(-comp_halo, 0, mode=2).sized(0, -comp_halo, mode=2);

# DCF.6abcd
var Nwell_ring    = Nwell.sized(space_to_Nwell)       - Nwell.sized(-space_to_Nwell);
var DNWELL_ring   = DNWELL.sized(space_to_DNWELL)     - DNWELL.sized(-space_to_DNWELL);
var LVPWELL_ring  = LVPWELL.sized(space_to_LVPWELL)   - LVPWELL.sized(-space_to_LVPWELL);
var Dualgate_ring = Dualgate.sized(space_to_Dualgate) - Dualgate.sized(-space_to_Dualgate);

# DCF.7a
# We expect the scribe line to be directly outside of the die
var scribe_line_ring = _frame - _frame.sized(-space_to_scribe_line);

var fill_region = _tile & _frame
                  - _tile.not(_tile.sized(-Poly2_extension))
                  - COMP_spacing.sized(space_to_COMP)
                  - Poly2.sized(space_to_Poly2)
                  - Nwell_ring
                  - DNWELL_ring
                  - LVPWELL_ring
                  - Dualgate_ring
                  - scribe_line_ring
                  - RES_MK.sized(space_to_RES_MK)
                  - Pad.sized(space_to_Pad)
                  - IND_MK.sized(space_to_IND_MK)
                  - NDMY.sized(space_to_NDMY);

_output(to_fill, fill_region)")

begin
  $ly.start_changes   # makes the layout handle many changes more efficiently
  tp.execute("Tiled fill")
ensure
  $ly.end_changes
end
