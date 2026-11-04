# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# rail_continuity.rb -- is the die's supply rail one shape, or many?
#
# The anchored die's lvsdb has 14,175 nets named VDD and 14,160 named VSS, against one of each in the
# CDL. That is either geometry (the rails really are cut every so often) or an extraction/stitching
# effect. This measures the geometry alone: clip a horizontal band on a known row-boundary rail,
# merge it, and report the connected components and their x extents. No deck, no netlist.
#
# Row grid (streamed GDS, dbu = 1 nm; DEF units are 2000/um so gds = def/2):
#   row 0  N   y 11760..15680   VSS at 11760, VDD at 15680
#   row 1  FS  y 15680..19600   VDD at 15680, VSS at 19600
#   row 2  N   y 19600..23520   VSS at 19600, VDD at 23520
#
#   klayout -b -r rail_continuity.rb -rd gds=<stream_out.gds> [-rd half=20]
HALF = ($half || 20).to_i
LAYERS = [
  ['nwell',  21, 0],
  ['metal1', 34, 0],
  ['metal2', 36, 0],
  ['metal3', 42, 0],
  ['metal4', 46, 0],
  ['metal5', 81, 0]
]

t0 = Time.now
ly = RBA::Layout.new
ly.read($gds)
ly.dbu = 1e-3 if ly.dbu.zero?
puts format('GDS dbu=%.4f um  cells=%d  top=%s  bbox=%s  read %.1f s',
            ly.dbu, ly.cells, ly.top_cell.name, ly.top_cell.bbox.to_s, Time.now - t0)

def band_report(ly, name, li, y, half)
  layer = ly.layer(li[0], li[1])
  all = RBA::Region.new(ly.top_cell.begin_shapes_rec(layer))
  band = RBA::Region.new(RBA::Box.new(0, y - half, ly.top_cell.bbox.right, y + half))
  m = (all & band).merged
  widths = []
  x0 = nil
  x1 = nil
  m.each do |p|
    bb = p.bbox
    widths << bb.width
    x0 = bb.left if x0.nil? || bb.left < x0
    x1 = bb.right if x1.nil? || bb.right > x1
  end
  widths.sort!.reverse!
  cover = widths.sum
  span = x0 && x1 ? x1 - x0 : 0
  far = widths.count { |w| w > 1_000_000 }
  puts format('%-7s %-7s n=%-5d widest=%-8s sumw=%-9s span=%-8s >1mm=%-4d top=%s',
              name, "y=#{y}", widths.size, widths[0].to_s, cover.to_s, span.to_s, far,
              widths.first(6).join(','))
end

[15680, 19600].each do |y|
  puts "-- band y=#{y} +- #{HALF} dbu (#{y / 1000.0} um)"
  LAYERS.each { |name, l, d| band_report(ly, name, [l, d], y, HALF) }
end
puts format('ELAPSED %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
