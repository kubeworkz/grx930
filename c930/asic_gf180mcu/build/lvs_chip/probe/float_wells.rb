# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# float_wells.rb -- which nwell components does no well tap touch?
#
# The netlist route could not name the unpaired wells: this build exposes no net id, and the
# pairing lookups either split one net into many or answer nil for all of them. The geometry does
# not need any of that. A well is tied to the supply only through a tap, and the only cell that
# draws one is `filltie` (measured: fill_1..fill_16 carry 21/0 NWELL but no 22/0 ACT; filltie
# carries both). So: merge the die's NWELL, subtract every component that touches a filltie's ACT,
# and what is left is the set of wells with no tap on them.
#
#   klayout -b -r float_wells.rb -rd gds=<die.gds>
GDS = $gds
abort("usage: -rd gds=<die.gds>") unless GDS

t0 = Time.now
ly = RBA::Layout.new
ly.read(GDS)
top = ly.top_cell
li_nw = ly.find_layer(21, 0)
li_act = ly.find_layer(22, 0)
abort("no 21/0 NWELL in #{GDS}") if li_nw.nil?
abort("no 22/0 ACT in #{GDS}") if li_act.nil?

nw = RBA::Region.new(top.begin_shapes_rec(li_nw))
nw.merge
puts "nwell polygons #{nw.count}"

tap = RBA::Region.new
n = 0
top.each_inst do |inst|
  next unless inst.cell.name.include?("filltie")
  n += 1
  base = RBA::Region.new(inst.cell.begin_shapes_rec(li_act))
  inst.cell_inst.each_cplx_trans do |ct|
    r = base.dup
    r.transform(ct)
    tap += r
  end
end
tap.merge
puts "filltie instances #{n}, tap polygons #{tap.count}"

tied = nw.interacting(tap)
floating = nw - tied
floating.merge
puts "nwell polygons touching a tap #{tied.count}; with no tap #{floating.count}"

rows = Hash.new(0)
floating.each { |p| rows[(p.bbox.center.y / 7840.0).round] += 1 }
puts "rows holding an untied well: " + rows.sort.map { |k, v| "#{k}=#{v}" }.first(40).join(" ")

big = []
floating.each { |p| big << p }
big.sort_by! { |p| -p.area }
puts "largest untied wells:"
big.first(15).each do |p|
  bb = p.bbox
  puts format("  area=%9d  x %8d..%-8d y %8d..%-8d  row %d", p.area, bb.left, bb.right, bb.bottom, bb.top,
              (bb.center.y / 7840.0).round)
end
puts format("DONE %.1f s", Time.now - t0)
$stdout.flush
exit!(0)
