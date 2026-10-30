# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
ly = RBA::Layout::new
ly.dbu = 0.001
top = ly.create_cell("probe")
M = 1000

def box(ly, top, l, d, x0, y0, x1, y1, m)
  li = ly.layer(l, d)
  top.shapes(li).insert(RBA::Box::new((x0 * m).round, (y0 * m).round, (x1 * m).round, (y1 * m).round))
end

# Case A: the foundry's own pairing -- 5x5 COMP dummy with a 5.6x5.6 Poly2 dummy over it
#         (fill_comp.rb 5.0 at origin 0,0 + fill_poly2.rb 5.6 at origin -0.3,-0.3)
box(ly, top, 22, 4,    0.0,   0.0,   5.0,   5.0, M)
box(ly, top, 30, 4,   -0.3,  -0.3,   5.3,   5.3, M)

# Case B: Poly2 dummy exactly on top of COMP dummy (same 5x5)
box(ly, top, 22, 4,   50.0,   0.0,  55.0,   5.0, M)
box(ly, top, 30, 4,   50.0,   0.0,  55.0,   5.0, M)

# Case C: Poly2 dummy over field oxide, no COMP dummy at all
box(ly, top, 30, 4,  100.0,   0.0, 105.6,   5.6, M)

# Case D: COMP dummy with no Poly2 dummy
box(ly, top, 22, 4,  150.0,   0.0, 155.0,   5.0, M)

# Case E: Poly2 dummy 5.6 centred on the COMP dummy (symmetric margin)
box(ly, top, 22, 4,  200.0,   0.0, 205.0,   5.0, M)
box(ly, top, 30, 4,  199.7,  -0.3, 205.3,   5.3, M)

ly.write($output)
puts "wrote #{$output}"
