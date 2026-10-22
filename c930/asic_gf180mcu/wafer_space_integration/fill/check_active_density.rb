require 'etc'

# Fast DCF.1b / PL.8 check on a filled GDS, without running the whole DRC deck.
#
# The gf180mcuD density deck (libs.tech/klayout/tech/drc/rule_decks/density.rb) computes
#   chip_area   = extent.sized(0.0).area                 # die outline area
#   DCF.1b      = (comp + comp_dummy).area / chip_area   # >= 25 %, <= 70 % (DCF.1d)
#   PL.8        = poly2.area / chip_area                 # >= 14 %
# with comp = 22/0, comp_dummy = 22/4, poly2 = 30/0 + 30/4 (generic_layers.rb: poly2 is
# register_layer(poly2_drawn + poly2_dummy)). This script reproduces those ratios so a fill
# change can be checked in seconds instead of running the deck; run the deck itself before
# tapeout.
#
# One mode difference, and it is visible on this die: generic_layers.rb sets
# `merge = (ctx.options.run_mode != 'deep')`, and the pre-check runs the density deck in DEEP mode
# (its step log says "Run mode: deep"), so the deck's per-layer areas are the sum over the *raw*
# polygons. Overlapping draws of the same layer then count more than once -- worth 1.365 points of
# die on 22/0 here (33.449 % as the deck computes it, 32.084 % merged) and nothing at all on 30/0
# and 30/4, which do not overlap. The verdict below is computed the deck's way, and the merged
# figure is printed beside any layer where the two disagree, so the difference cannot hide.
#
# Usage:
#   klayout -b -zz -r check_active_density.rb -rd input=<gds> [-rd topcell=<cell>] \
#           [-rd comp_halo_um=<um>] [-rd pair_metal_um=<um>]
#
# comp_halo_um / pair_metal_um are printed back so a report makes clear which fill spacing the
# numbers belong to. Exits 0 when DCF.1b and PL.8 pass, 1 otherwise.

$stdout.sync = true

ly = RBA::Layout::new
ly.read($input)

top = $topcell ? ly.cell($topcell) : ly.top_cell
# Region#area is in dbu^2 (Cell#dbbox is in micron, so it must not be used here); the deck's
# chip_area is extent.sized(0.0).area over the same die box.
die = top.bbox
die_area = die.width.to_f * die.height.to_f

def layer_area(ly, cell, layer, datatype, merged)
  li = ly.layer(layer, datatype)
  return 0.0 if li.nil?
  r = RBA::Region::new(ly.begin_shapes(cell.cell_index, li))
  r.merge if merged
  r.area
end

# The deck's own mode (deep: raw polygons), and the merged figure beside it where they differ.
def areas(ly, top, layer, datatype)
  raw = layer_area(ly, top, layer, datatype, false)
  mrg = layer_area(ly, top, layer, datatype, true)
  [raw, mrg]
end

def show(label, layer, datatype, a, die_area)
  raw, mrg = a
  line = format("%-13s %2d/%-2d       : %6.3f %% of die", label, layer, datatype, raw / die_area * 100)
  line += format("   (merged %.3f %%)", mrg / die_area * 100) if (raw - mrg).abs > die_area * 1e-5
  puts line
end

comp       = areas(ly, top, 22, 0)
comp_dummy = areas(ly, top, 22, 4)
poly2      = areas(ly, top, 30, 0)
poly2_dum  = areas(ly, top, 30, 4)

die_um = die.width * die.height * ly.dbu * ly.dbu

dcf1b = (comp[0] + comp_dummy[0]) / die_area.to_f
pl8   = (poly2[0] + poly2_dum[0]) / die_area.to_f

printf("die bbox                 : %.1f x %.1f um = %.0f um^2\n",
       die.width * ly.dbu, die.height * ly.dbu, die_um)
show("COMP",       22, 0, comp, die_area)
show("COMP dummy", 22, 4, comp_dummy, die_area)
show("Poly2",      30, 0, poly2, die_area)
show("Poly2 dummy", 30, 4, poly2_dum, die_area)
puts   "------------------------------------------------------------"

status = 0

def verdict(name, value, lo, hi)
  ok = value >= lo && (hi.nil? || value <= hi)
  range = hi ? "#{lo}..#{hi}" : ">= #{lo}"
  printf("%-8s %-12s : %6.3f %%  %s\n", name, "[#{range}]", value, ok ? "PASS" : "FAIL")
  ok
end

status |= 1 unless verdict("DCF.1b", dcf1b * 100, 25.0, 70.0)
status |= 2 unless verdict("DCF.1d", dcf1b * 100, 0.0, 70.0)
status |= 4 unless verdict("PL.8", pl8 * 100, 14.0, nil)

if $comp_halo_um || $pair_metal_um
  printf("fill spacing             : COMP halo %s um, DPF.12/13 metal halo %s um\n",
         $comp_halo_um || "0", $pair_metal_um || "0")
end

# exit! rather than exit: klayout's -b -r driver swallows SystemExit and would return 0
$stdout.flush
$stderr.flush
exit!(status == 0 ? 0 : 1)
