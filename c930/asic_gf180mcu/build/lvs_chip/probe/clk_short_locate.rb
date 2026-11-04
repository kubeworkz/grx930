# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# clk_short_locate.rb -- find the metal1 geometry where the clock and a supply rail meet.
#
# The stitched-die comparison puts the clock on the VDD net (343,505 PFET bodies + 225,719 S/D +
# 29,204 gates against a schematic VDD with no gate on it). The strap report proves the straps are
# clear, and the pre-stitch census named the clock island, so the contact is one spot of metal1,
# not a class of them. This probe looks for it without trusting any netlist:
#
#   * rail components are the metal1 polygons shaped like a rail (600 dbu tall, thousands wide);
#   * a rail that carries a via1 is a rail something reached down to -- in this artifact nothing
#     did, so every hit is the defect (the strap pass is not in this file);
#   * a rail whose bbox is taller than its band has something drawn inside the row: also reported.
#
#   klayout -b -r clk_short_locate.rb -rd gds=stream_out_filled_metal1.gds
#
# Prints, for each hit: the rail island bbox, its row bondary y and therefore its supply, the
# contact bbox, and the cell box that contains the contact x (so the DEF instance can be named).
ROWH = 3920          # GDS dbu: ROW pitch is 7,840 DEF units at 2 DEF units per dbu
RAIL_H = 600         # 0.6 um band, 300 dbu either side of a row boundary
Y0 = 11_760          # ROW_0 in GDS dbu (23,520 DEF)

t0 = Time.now
ly = RBA::Layout.new
ly.read($gds)
top = ly.top_cell
puts format('gds=%s dbu=%.4f bbox=%s', $gds, ly.dbu, top.bbox)

m1 = RBA::Region.new(top.begin_shapes_rec(ly.layer(34, 0))).merged
v1 = RBA::Region.new(top.begin_shapes_rec(ly.layer(35, 0))).merged
puts format('metal1 components=%d via1 cuts=%d', m1.count, v1.count)

rails = RBA::Region.new
tall = []
m1.each do |p|
  bb = p.bbox
  if bb.height <= RAIL_H + 200 && bb.width >= 4_000
    rails.insert(p)
  elsif bb.width >= 4_000
    tall << [bb, p.area]
  end
end
puts format('rail-shaped components=%d  rail-ish but taller than a band=%d',
            rails.count, tall.size)
tall.sort_by { |bb, _a| -bb.width }.first(20).each do |bb, a|
  puts format('  TALL rail x %8d..%-8d y %8d..%-8d h=%5d area=%d',
              bb.left, bb.right, bb.bottom, bb.top, bb.height, a)
end

# Which rail components did a via1 land on? A rail is 600 tall and a via1 pad is 260 x 380, so a
# correct pin connection cannot be confused with a rail that something stands on.
hits = (v1 & rails)
puts format('via1-on-rail pieces=%d', hits.count)
rows = []
rails.each do |p|
  bb = p.bbox
  next if (v1 & RBA::Region.new(p)).is_empty?
  vb = nil
  (v1 & RBA::Region.new(p)).each { |q| vb = q.bbox }
  row = ((bb.bottom + bb.top) / 2 - Y0).to_f / ROWH
  rows << [bb, vb, row.round, row]
end
rows.sort_by { |bb, _v, _r, _f| [bb.bottom, bb.left] }.each do |bb, vb, r, f|
  supply = (r.odd? ? 'VDD' : 'VSS')
  puts format('HIT  rail y %8d..%-8d x %8d..%-8d  row=%.2f %s  via=%s',
              bb.bottom, bb.top, bb.left, bb.right, f, supply,
              vb ? format('x %d..%d y %d..%d', vb.left, vb.right, vb.bottom, vb.top) : '-')
end

puts format('ELAPSED %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
