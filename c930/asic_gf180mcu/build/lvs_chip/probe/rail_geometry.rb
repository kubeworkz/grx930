# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# rail_geometry.rb -- where the supply rails actually sit, and whether they join across rows.
#
# rail_continuity.rb found no metal1 at the row-box edges (y = 15680, 19600) but a full-width metal5
# strap at both. This finds the rails in a two-row window and reports the merged metal1 components
# in that window, so "one rail per row" vs "a fragment every N cells" can be read off the geometry.
#
#   klayout -b -r rail_geometry.rb -rd gds=<stream_out.gds> [-rd x0=500000 -rd w=200000
#                                                  -rd y0=11760 -rd y1=23520]
X0 = ($x0 || 500_000).to_i
W  = ($w  || 200_000).to_i
Y0 = ($y0 || 11_760).to_i
Y1 = ($y1 || 23_520).to_i

t0 = Time.now
ly = RBA::Layout.new
ly.read($gds)
puts format('dbu=%.4f bbox=%s', ly.dbu, ly.top_cell.bbox.to_s)

def shapes_in(ly, li, box)
  layer = ly.layer(li[0], li[1])
  all = RBA::Region.new(ly.top_cell.begin_shapes_rec(layer))
  all & RBA::Region.new(box)
end

box = RBA::Box.new(X0, Y0, X0 + W, Y1)
m = shapes_in(ly, [34, 0], box).merged
puts "-- metal1 merged in x[#{X0},#{X0 + W}] y[#{Y0},#{Y1}]: #{m.count} components"
i = 0
m.each do |p|
  break if i >= 24
  bb = p.bbox
  puts format('   %2d  x %8d..%-8d y %8d..%-8d  w=%7d h=%5d verts=%d',
              i, bb.left, bb.right, bb.bottom, bb.top, bb.width, bb.height, p.num_points)
  i += 1
end

# metal5 strap coverage at the row boundaries: one strap per boundary, or more?
m5 = shapes_in(ly, [81, 0], box).merged
puts "-- metal5 merged in the same window: #{m5.count} components"
i = 0
m5.each do |p|
  break if i >= 12
  bb = p.bbox
  puts format('   %2d  x %8d..%-8d y %8d..%-8d  w=%7d h=%5d',
              i, bb.left, bb.right, bb.bottom, bb.top, bb.width, bb.height)
  i += 1
end

# What does a library cell look like? The rail's y inside the cell decides whether box anchoring
# lines the rails up or leaves a gap.
if $cellgds
  cl = RBA::Layout.new
  cl.read($cellgds)
  c = cl.cell($cell || 'mux2_1')
  if c
    puts "-- cell #{c.name} bbox=#{c.bbox.to_s} (dbu=#{cl.dbu})"
    r = RBA::Region.new(c.begin_shapes_rec(cl.layer(34, 0))).merged
    rows = []
    r.each { |p| bb = p.bbox; rows << [bb.bottom, bb.top, bb.left, bb.right, bb.width] if bb.width > 2_000 }
    rows.sort.each do |b, t, l, rr, w|
      puts format('   rail? y %5d..%-5d x %5d..%-5d w=%5d', b, t, l, rr, w)
    end
  else
    puts "-- cell #{$cell} not in #{$cellgds}"
  end
end
puts format('ELAPSED %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
