# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_net_shapes.rb -- the layout shapes of the biggest net in an lvsdb, layer by layer.
#
# The extraction carries net-to-shape mapping, so the question "where does the clock meet a rail"
# does not have to be guessed from merged geometry: read the net, ask for its metal1 and via1
# shapes, and the contact is the shape that is neither a rail nor a pin. Run on the pre-stitch
# lvsdb, where the clock net still holds one island and 29,484 terminals, not 600,232.
#
#   klayout -b -r lvsdb_net_shapes.rb -rd file=<report.lvsdb> [-rd limit=60]
FILE = $file
LIMIT = ($limit || 60).to_i

t0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
puts format('lvsdb=%s  loaded in %.1f s', FILE, Time.now - t0)
nl = lvs.xref.netlist_a
count = 0
nl.each_circuit { |_c| count += 1 }
puts "layout netlist circuits=#{count}"

top = nil
nl.each_circuit { |c| top = c if top.nil? }
puts "top=#{top.name}"

best = nil
best_n = -1
top.each_net do |n|
  next unless n.name.to_s.include?('i_clk')
  c = n.terminal_count
  if c > best_n
    best_n = c
    best = n
  end
end
if best.nil?
  top.each_net do |n|
    c = n.terminal_count
    if c > best_n
      best_n = c
      best = n
    end
  end
end
puts "net: id=#{best.cluster_id} terminals=#{best_n} name=#{best.name.to_s[0, 60]}"

# The lvsdb names its layers l1..l169, so identify them by their GDS numbers.
want = {}
lvs.layer_indexes.each do |i|
  info = lvs.layer_info(i)
  next if info.nil?
  want[[info.layer, info.datatype]] = i if info.layer >= 30 && info.layer <= 50
end
puts "layer index map (30..50): #{want.sort.inspect}"

i_lay = lvs.internal_layout
i_cell = lvs.internal_top_cell
puts "internal layout: dbu=#{i_lay.dbu} layers=#{i_lay.layers} top=#{i_cell.name}"
want.sort.each do |(ln, dt), li|
  layer_region = RBA::Region.new(i_cell.begin_shapes_rec(li))
  begin
    r = lvs.shapes_of_net(best, layer_region)
  rescue StandardError => e
    puts format('-- %d/%d (layer %d): SKIP %s', ln, dt, li, e.message[0, 60])
    next
  end
  puts format('-- %d/%d (layer %d): %d shapes', ln, dt, li, r.count)
  i = 0
  r.each do |p|
    bb = p.bbox
    puts format('   %8d..%-8d x %8d..%-8d  w=%6d h=%5d area=%d',
                bb.left, bb.right, bb.bottom, bb.top, bb.width, bb.height, p.area)
    i += 1
    break if i >= LIMIT
  end
end
$stdout.flush
exit!(0)
