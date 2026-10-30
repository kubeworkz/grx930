# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# Where does the dummy COMP lose its Poly2 partner? For each DPF exclusion, how much of the
# paired area it removes, and how much of the legal zone is still empty (i.e. could carry more
# dummy COMP, and with it more dummy Poly2).
#
#   klayout -b -zz -r measure_paired_zone.rb -rd input=<filled.gds>
$stdout.sync = true

$ly = RBA::Layout::new
$ly.read($input)
top = $ly.top_cell

def reg(top, l, d)
  li = $ly.layer(l, d)
  li ? RBA::Region::new(top.begin_shapes_rec(li)) : RBA::Region.new
end

def um(v)
  (v / $ly.dbu).round
end

DIE_UM2 = 20_139_704.0

chip    = RBA::Region::new(top.bbox)
dummy   = reg(top, 22, 4)
partner = dummy.sized(um(0.3))
poly2   = reg(top, 30, 0)

puts format("die            : %12.0f um^2", chip.area * $ly.dbu**2)
puts format("dummy COMP     : %12.0f um^2  (%5.3f %% of die)", dummy.area * $ly.dbu**2,
            dummy.area * $ly.dbu**2 / DIE_UM2 * 100)
puts format("paired (cmp+0.3):%12.0f um^2  (%5.3f %% of die)", partner.area * $ly.dbu**2,
            partner.area * $ly.dbu**2 / DIE_UM2 * 100)
puts

excl = RBA::Region.new
list = [["Poly2", 30, 0, 5.0], ["RES_MK", 110, 5, 19.7], ["NDMY", 111, 5, 29.7],
        ["PMNDMY", 152, 5, 8.0], ["MTPMK", 122, 5, 3.0], ["Pad", 37, 0, 6.7],
        ["Metal1", 34, 0, 2.0], ["Metal2", 36, 0, 2.0], ["IND_MK", 151, 5, 3.0]]

puts "per-exclusion cost (whole paired squares dropped):"
list.each do |name, l, d, dist|
  e = reg(top, l, d).sized(um(dist))
  hit = partner.interacting(e).area * $ly.dbu**2
  printf("  %-8s %5.1f um : %12.0f um^2  (%5.3f %% of die)\n", name, dist, hit, hit / DIE_UM2 * 100)
  excl += e
end

[["Nwell", 21, 0, 1.0], ["DNWELL", 12, 0, 2.0], ["LVPWELL", 204, 0, 1.0], ["Dualgate", 55, 0, 1.0]].each do |name, l, d, dist|
  r = reg(top, l, d)
  e = r.sized(um(dist)) - r.sized(-um(dist))
  hit = partner.interacting(e).area * $ly.dbu**2
  printf("  %-8s %5.1f um : %12.0f um^2  (%5.3f %% of die)\n", name, dist, hit, hit / DIE_UM2 * 100)
  excl += e
end

scribe = chip - chip.sized(-um(26.0))
hit = partner.interacting(scribe).area * $ly.dbu**2
printf("  %-8s %5.1f um : %12.0f um^2  (%5.3f %% of die)\n", "scribe", 26.0, hit, hit / DIE_UM2 * 100)
excl += scribe

kept = partner.not_interacting(excl)
printf("\nkept pairs     : %12.0f um^2  (%5.3f %% of die)\n", kept.area * $ly.dbu**2,
       kept.area * $ly.dbu**2 / DIE_UM2 * 100)
printf("Poly2 drawn    : %12.0f um^2  (%5.3f %% of die)\n", poly2.area * $ly.dbu**2,
       poly2.area * $ly.dbu**2 / DIE_UM2 * 100)

# How much legal room is still empty -- i.e. what another (denser) COMP fill in the paired zone
# could still use, with its own 1.9 um spacing to the existing squares.
legal = chip - excl - scribe
free  = legal - dummy.sized(um(1.9))
printf("\nlegal zone     : %12.0f um^2  (%5.3f %% of die)\n", legal.area * $ly.dbu**2,
       legal.area * $ly.dbu**2 / DIE_UM2 * 100)
printf("empty & legal  : %12.0f um^2  (%5.3f %% of die)\n", free.area * $ly.dbu**2,
       free.area * $ly.dbu**2 / DIE_UM2 * 100)
printf("-> 6x6 @ 1.9 um slots in it: about %d squares (%.3f %% of die of Poly2 if paired)\n",
       (free.area * $ly.dbu**2 / 62.41).to_i, (free.area * $ly.dbu**2 / 62.41).to_i * 43.56 / DIE_UM2 * 100)
