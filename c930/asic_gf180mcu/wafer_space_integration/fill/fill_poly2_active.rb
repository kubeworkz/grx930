# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# Dummy Poly2 fill, generated from the dummy COMP the COMP step just placed.
#
# Replacement for the GF180MCU PDK's libs.tech/klayout/tech/scripts/fill_poly2.rb (Apache-2.0,
# Copyright 2022 GlobalFoundries PDK Authors). Two measured reasons why this is not a copy:
#
# 1. DPF.1 ("Dummy Poly2 is generated on top of dummy COMP") is checked, and it is strict:
#    every dummy Poly2 shape must *cover* a dummy COMP shape. Measured with probe_dpf1.rb /
#    probe_dpf1b.rb against the gf180mcuD deck -- a Poly2 square alone over field oxide, a
#    Poly2 fragment inside a COMP square, and a Poly2 sliver touching a COMP square are all
#    violations; a Poly2 square that covers a COMP square is clean, with or without a margin.
#    So the foundry's second, independent fill region cannot satisfy DPF.1 wherever its own
#    exclusions cut a square: the partner is derived here from the dummy COMP itself, grown by
#    0.3 um a side (the foundry's own COMP-to-Poly2 ratio: fill_comp.rb's 5.0 square against
#    fill_poly2.rb's 5.6), which keeps the covering exact whatever the COMP fill placed --
#    the 6.0 um COMP squares of pass 1 give 6.6 um Poly2 squares, the 3.0 um pattern the
#    foundry default gives 3.6 um.
# 2. PL.8 (Poly2 over the whole die >= 14 %) cannot be reached from the foundry's region: its
#    Poly2.sized(5) exclusion covers the entire standard-cell core, so the foundry's dummy
#    Poly2 only ever lands in the die margins and saturates at ~3.4 % of the die. Pairing it
#    with the dummy COMP instead makes the Poly2 dummy grow with the COMP dummy.
#
# The COMP fill keeps dummy COMP 3.5 um from circuit COMP (DCF.4), so DPF.4 (3.2 um) is met by
# construction; every other DPF distance is applied explicitly below, at the deck's own value --
# except DPF.12/DPF.13 (dummy Poly2 to circuit Metal1/Metal2, 2 um), which this deck does not
# check at all:
#
#   dummy_poly2.rb lines 97-114 of the gf180mcuD deck comment both rules out, with the reason
#   ("For now this is disabled since wafer.space moves all fill shapes to active metal layers"),
#   and the DUMMY_SUB_PREV they are guarded by is defined nowhere -- it appears only in that
#   comment and the matching one in dummy_metal.rb. `grep -rn DUMMY_SUB_PREV` over the whole
#   pre-check image's PDK finds no definition.
#
# Honouring them anyway is what kept PL.8 failing, and that is the measurement that refuted the
# earlier version of this file (which applied all ten distances "for the guideline"):
# fillrun/zone.log attributes 13.644 % of the die of dropped pairs to the Metal1 halo and
# 4.485 % to Metal2 -- together ~80 % of every pair the COMP fill generates -- while the whole
# rest of the exclusion set costs 1.03 %. With the two halos applied, dummy Poly2 saturates at
# 3.85 % of the die (PL.8 = 13.09 %, FAIL); with them at 0 the pair survives wherever the
# *checked* rules allow it.
#
# pair_metal_um re-enables them (set it to 2.0) for a deck or a pre-check that turns
# DUMMY_SUB_PREV on, or for a stricter internal guideline. 0.0 is the deck as it actually runs.
#
# Whole shapes are filtered rather than clipped (Region#not_interacting) so a surviving Poly2
# square always covers its COMP square whole.

def p2_region(layer_index)
  RBA::Region::new($top_cell.begin_shapes_rec(layer_index))
end

def p2_um(v)
  (v / $ly.dbu).round
end

fill_layer = Poly2_Dummy

pair_metal_um = ($pair_metal_um || 0.0).to_f
pair_metal_um = 0.0 if pair_metal_um < 0.0

puts "Pairing dummy Poly2 with dummy COMP…"
puts format("  DPF.12/DPF.13 metal halo: %.1f um%s", pair_metal_um,
            pair_metal_um.zero? ? " (off: the gf180mcuD deck comments both rules out)" : "")

$ly.start_changes
begin
  comp_dummy = p2_region(COMP_Dummy)

  chip = RBA::Region::new($top_cell.bbox)

  # GROW is the foundry's own COMP-to-Poly2 ratio (5.0 -> 5.6): the partner covers the COMP
  # square whole, so DPF.1 holds by construction.
  grow = 0.3
  partners = comp_dummy.sized(p2_um(grow))

  # DPF exclusions, at the deck's own distances. DPF.5 runs from the drawn Poly2 layer, the
  # rest from their own layers.
  excl = RBA::Region::new
  [[Poly2, 5.0],        # DPF.5
   [RES_MK, 19.7],      # DPF.8
   [NDMY, 29.7],        # DPF.11
   [PMNDMY, 8.0],       # DPF.19
   [MTPMK, 3.0],        # DPF.16
   [Pad, 6.7],          # DPF.9
   [IND_MK, 3.0]].each do |layer, dist|  # DPF.14
    excl += p2_region(layer).sized(p2_um(dist))
  end

  # DPF.12 (Metal1 2 um) and DPF.13 (Metal2 2 um): commented out of the deck -- see the header.
  # 2.0 is the deck's own value when they are enabled; anything <= 0 applies neither.
  [[Metal1, pair_metal_um], [Metal2, pair_metal_um]].each do |layer, dist|
    next if dist <= 0.0
    excl += p2_region(layer).sized(p2_um(dist))
  end

  # DPF.6abcd: space from dummy Poly2 to a well boundary
  [[Nwell, 1.0], [DNWELL, 2.0], [LVPWELL, 1.0], [Dualgate, 1.0]].each do |layer, dist|
    r = p2_region(layer)
    excl += r.sized(p2_um(dist)) - r.sized(-p2_um(dist))
  end

  # DPF.7: dummy Poly2 stays 26 um inside the die edge (the scribe line is directly outside it)
  excl += chip - chip.sized(-p2_um(26.0))

  # Whole-shape filter: a Poly2 square either fits with every DPF distance intact or is dropped,
  # so it never ends up as a fragment that no longer covers the COMP square it belongs to.
  poly2_dummy = partners.not_interacting(excl)

  # partners is the un-filtered pair region; the squares do not overlap (the pattern keeps
  # 1.9 um between the 0.6 um-grown squares), so its area is the sum over every pair.
  area_before = comp_dummy.area * $ly.dbu * $ly.dbu
  area_paired = partners.area * $ly.dbu * $ly.dbu
  area_after  = poly2_dummy.area * $ly.dbu * $ly.dbu
  printf("  dummy COMP      : %12.0f um^2\n", area_before)
  printf("  dummy Poly2     : %12.0f um^2 (%d squares)\n", area_after, poly2_dummy.count)
  printf("  dropped by DPF  : %6.1f %% of the paired squares\n",
         (1.0 - area_after / area_paired) * 100)

  $fill_cell_poly2.shapes(fill_layer).insert(poly2_dummy)
ensure
  $ly.end_changes
end
