# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# rail_merge.rb -- how many separate metal1 pieces does the die have?
#
# The fill pass is meant to join the metal1 VDD/VSS rails that stop at every run of cells. If it
# did, the merged metal1 region count drops sharply and the widest pieces span a row; if the rails
# only moved without touching, the count stays in the thousands. This is geometry only -- the
# electrical answer comes from the net census.
#
#   klayout -b -r rail_merge.rb -rd gds=<stream_out.gds>
t0 = Time.now
ly = RBA::Layout.new
ly.read($gds)
puts format('dbu=%.4f bbox=%s read %.1f s', ly.dbu, ly.top_cell.bbox.to_s, Time.now - t0)

[['metal1', 34, 0], ['metal2', 36, 0]].each do |name, l, d|
  layer = ly.layer(l, d)
  reg = RBA::Region.new(ly.top_cell.begin_shapes_rec(layer))
  before = reg.count
  m = reg.merged
  widths = []
  spans = 0
  m.each do |p|
    b = p.bbox
    widths << b.width
    spans += 1 if b.width > 1_000_000
  end
  widths.sort!.reverse!
  puts format('%-6s shapes=%-8d merged=%-7d wider-than-1mm=%-5d widest=%-9d median=%-8d',
              name, before, m.count, spans, (widths[0] || 0), (widths[widths.size / 2] || 0))
  puts format('       top widths (dbu): %s', widths.first(6).join(', '))
end
puts format('ELAPSED %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
