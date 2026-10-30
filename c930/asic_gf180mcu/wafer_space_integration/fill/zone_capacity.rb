# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# How much room is left for dummy COMP in the zone where dummy Poly2 can be paired with it?
# One region-algebra pass, no per-rule queries, so it is quick.
#
#   klayout -b -zz -r zone_capacity.rb -rd input=<filled.gds>
#
# The exclusion set below is the ALL-TEN-DISTANCE policy, i.e. DPF.12/DPF.13 included at their
# deck value of 2 um -- which is NOT what fill_poly2_active.rb does (it ships with pair_metal_um 0,
# because the deck comments both rules out). That is deliberate: this script prices the option.
# Run it on the fill to see what the zone would be worth if the two metal halos were honoured, and
# compare `free, 1.9 clear` with the same figure from measure_paired_zone.rb -- the difference is
# what re-enabling them costs. For the zone the fill actually uses, drop the two Metal entries.
$stdout.sync = true

$ly = RBA::Layout::new
$ly.read($input)
# $top, not a local: layer_region below is a top-level method and cannot see a local.
$top = $ly.top_cell
DIE = 20_139_704.0

def um(v)
  (v / $ly.dbu).round
end

def layer_region(l, d)
  RBA::Region::new($top.begin_shapes_rec($ly.layer(l, d)))
end

def pct(r)
  printf("%12.0f um^2  (%6.3f %% of die)", r.area * $ly.dbu**2, r.area * $ly.dbu**2 / DIE * 100)
end

chip  = RBA::Region::new($top.bbox)
dummy = layer_region(22, 4)

puts "policy: all ten DPF distances, DPF.12/DPF.13 included at 2 um (see the header)"
print "dummy COMP            : "
puts pct(dummy)

# The DPF exclusions at the deck's own values (the fill grows its squares by 0.3 afterwards,
# which is why its own zone uses rule + 0.3 and this one does not).
z = chip.dup
[[30, 0, 5.0], [110, 5, 19.7], [111, 5, 29.7], [152, 5, 8.0], [122, 5, 3.0],
 [37, 0, 6.7], [34, 0, 2.0], [36, 0, 2.0], [151, 5, 3.0]].each do |l, d, dist|
  z -= layer_region(l, d).sized(um(dist))
end
[[21, 0, 1.0], [12, 0, 2.0], [204, 0, 1.0], [55, 0, 1.0]].each do |l, d, dist|
  r = layer_region(l, d)
  z -= r.sized(um(dist)) - r.sized(-um(dist))
end
z -= (chip - chip.sized(-um(26.0)))

print "Poly2 pairing zone    : "
puts pct(z)

in_zone = dummy & z
print "  dummy COMP in it    : "
puts pct(in_zone)

free = z - dummy.sized(um(1.9))
print "  free, 1.9 clear     : "
puts pct(free)

poly2 = layer_region(30, 0)
print "Poly2 drawn           : "
puts pct(poly2)

# every COMP square inside the zone gets a Poly2 partner (the zone already excludes the DPF
# halos, so the grown square keeps every distance)
kept = in_zone.sized(um(0.3))
print "  paired Poly2        : "
puts pct(kept)

puts
printf("PL.8 if the free area were filled at each pattern coverage:\n")
[3.0, 6.0, 12.0, 20.0].each do |s|
  cover = s * s / ((s + 1.9)**2 - 1.6 * 1.6)
  gain_comp = free.area * $ly.dbu**2 * cover
  gain_p2   = gain_comp * (s + 0.6)**2 / s**2
  printf("  cell %5.1f um (%.0f %% coverage): +%7.0f um^2 COMP, +%7.0f um^2 Poly2 -> PL.8 %.3f %%\n",
         s, cover * 100, gain_comp, gain_p2,
         (kept.area * $ly.dbu**2 + gain_p2) / DIE * 100 + poly2.area * $ly.dbu**2 / DIE * 100)
end
