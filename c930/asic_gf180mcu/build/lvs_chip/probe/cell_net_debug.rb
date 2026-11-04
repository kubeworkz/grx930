# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# cell_net_debug.rb -- where does shapes_of_net put a cell-internal net?
#
#   klayout -b -r cell_net_debug.rb -rd file=<cell report.lvsdb> -rd gds=<library.gds> \
#           -rd cell=<cell> [-rd want=NCKI]
FILE = $file
GDS = $gds
CELL = $cell
WANT = ($want || 'NCKI').to_s.upcase

lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
x = lvs.xref
cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-PAIR') unless cp

def nname(o)
  return o.expanded_name if o && o.respond_to?(:expanded_name)
  return o.name if o && o.respond_to?(:name)
  o.to_s
end

net = nil
x.each_net_pair(cp) do |p|
  next unless p.first && p.second
  if nname(p.second).upcase == WANT
    net = p.first
    break
  end
end
abort("NO-NET #{WANT}") unless net
puts "net #{WANT} -> #{nname(net)} terminals=#{net.terminal_count}"

lib = RBA::Layout.new
lib.read(GDS)
cell = lib.cell(CELL)
puts "GDS cell bbox #{cell.bbox.to_s} dbu=#{lib.dbu}"
puts "lvsdb internal layout bbox #{lvs.internal_layout.top_cell.bbox.to_s} dbu=#{lvs.internal_layout.dbu}"

hits = 0
lvs.layer_names.sort.each do |nm|
  region = lvs.layer_by_name(nm)
  next if region.nil?
  shapes = begin
    lvs.shapes_of_net(net, region)
  rescue StandardError
    nil
  end
  next if shapes.nil? || shapes.count.zero?
  hits += 1
  bb = shapes.bbox
  puts format('  %-6s net_shapes=%-3d bbox %s  first=%s', nm, shapes.count, bb.to_s,
              shapes.each.first.inspect[0, 90])
  puts "         region bbox #{region.bbox} count=#{region.count}"
end
puts "LAYERS WITH NET SHAPES #{hits}"
$stdout.flush
exit!(0)
