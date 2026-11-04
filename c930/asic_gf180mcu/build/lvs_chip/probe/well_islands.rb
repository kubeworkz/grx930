# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# well_islands.rb -- how many separate well regions does the die's geometry have?
#
# The lvsdb has 14,175 nets named VDD and 14,160 named VSS, each averaging ~24 body terminals, against
# one of each in the CDL. If those counts equal the number of connected nwell / pwell regions, the
# fragmentation is geometry (separate wells), not an extractor artefact: the netter merged exactly
# what the drawn wells connect and no more.
#
#   klayout -b -r well_islands.rb -rd gds=<stream_out.gds>
t0 = Time.now
ly = RBA::Layout.new
ly.read($gds)
puts format('dbu=%.4f bbox=%s read %.1f s', ly.dbu, ly.top_cell.bbox.to_s, Time.now - t0)

[['nwell', 21, 0], ['pwell', 20, 0]].each do |name, l, d|
  layer = ly.layer(l, d)
  reg = RBA::Region.new(ly.top_cell.begin_shapes_rec(layer))
  before = reg.count
  m = reg.merged
  sizes = []
  m.each { |p| sizes << p.bbox.area }
  sizes.sort!.reverse!
  big = sizes.count { |a| a > 1_000_000 }  # > 1000 um^2
  puts format('%-6s polygons=%-7d merged=%-7d areas>1000um2=%-6d widest=%-10d median=%-8d min=%d',
              name, before, m.count, big, (sizes[0] || 0), (sizes[sizes.size / 2] || 0), (sizes[-1] || 0))
  puts format('       top areas (dbu^2): %s', sizes.first(8).join(', '))
end
puts format('ELAPSED %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
