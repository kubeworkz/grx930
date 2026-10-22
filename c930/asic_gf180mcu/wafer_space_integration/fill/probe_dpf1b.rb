ly = RBA::Layout::new
ly.dbu = 0.001
top = ly.create_cell("probe")
M = 1000

def box(ly, top, l, d, x0, y0, x1, y1, m)
  li = ly.layer(l, d)
  top.shapes(li).insert(RBA::Box::new((x0 * m).round, (y0 * m).round, (x1 * m).round, (y1 * m).round))
end

# A2 (control, expected clean): the foundry pairing, 5.0 COMP + 5.6 Poly2 with a 0.3 margin
box(ly, top, 22, 4,    0.0, 0.0,   5.0, 5.0, M)
box(ly, top, 30, 4,   -0.3, -0.3,  5.3, 5.3, M)

# C2 (control, expected violation): Poly2 dummy with no COMP dummy
box(ly, top, 30, 4,  100.0, 0.0, 105.6, 5.6, M)

# F: Poly2 covering only the left half of the COMP dummy (inside it, covers nothing whole)
box(ly, top, 22, 4,  250.0, 0.0, 255.0, 5.0, M)
box(ly, top, 30, 4,  250.0, 0.0, 252.5, 5.0, M)

# G: Poly2 sliver immediately outside the COMP dummy (shares an edge, overlaps nothing)
box(ly, top, 22, 4,  300.0, 0.0, 305.0, 5.0, M)
box(ly, top, 30, 4,  305.0, 0.0, 305.3, 5.0, M)

# H: Poly2 overlapping the COMP dummy but hanging 1.6 um off to the right
box(ly, top, 22, 4,  350.0, 0.0, 355.0, 5.0, M)
box(ly, top, 30, 4,  351.0, 0.0, 356.6, 5.6, M)

# J: Poly2 = COMP dummy grown by exactly 0.3 (symmetric margin), thin COMP
box(ly, top, 22, 4,  400.0, 0.0, 401.0, 1.0, M)
box(ly, top, 30, 4,  399.7, -0.3, 401.3, 1.3, M)

# K: Poly2 grown 0.5 around the COMP dummy (margin larger than the foundry's 0.3)
box(ly, top, 22, 4,  450.0, 0.0, 455.0, 5.0, M)
box(ly, top, 30, 4,  449.5, -0.5, 455.5, 5.5, M)

ly.write($output)
puts "wrote #{$output}"
