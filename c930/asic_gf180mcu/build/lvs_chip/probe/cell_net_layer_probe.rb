# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# cell_net_layer_probe.rb -- which lvsdb layer index carries a cell-internal net's shapes?
#
# `lvs.shapes_of_net(net, region)` refuses a region built from an internal-layout layer
# ("Non-hierarchical layers cannot be used in netlist extraction"), so the region must come from
# one of the netlist's own layer indexes. Those indexes carry no GDS number in this run
# (`lvs.layer_info` reports -1/-1 for 100 of 102), so the layer has to be identified by content:
# count the net's shapes per index, and count each index's shapes over the whole cell.
#
#   klayout -b -r cell_net_layer_probe.rb -rd file=<cell report.lvsdb> -rd want=NCKI
FILE = $file
WANT = ($want || 'NCKI').to_s.upcase

lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
x = lvs.xref
X = RBA::NetlistCrossReference
cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-PAIR') unless cp
i_cell = lvs.internal_top_cell
puts "cell=#{i_cell.name} indexes=#{lvs.layer_indexes.size}"

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
puts "net #{WANT} -> layout #{nname(net)} terminals=#{net.terminal_count}"

lvs.layer_indexes.sort.each do |li|
  info = lvs.layer_info(li)
  total = RBA::Region.new(i_cell.begin_shapes_rec(li)).count
  next if total.zero?
  hit = begin
    lvs.shapes_of_net(net, RBA::Region.new(i_cell.begin_shapes_rec(li))).count
  rescue StandardError => e
    "ERR #{e.message[0, 50]}"
  end
  next if hit == 0
  puts format('  index %3d info=%s/%s cell_shapes=%-7d net_shapes=%s',
              li, info.layer, info.datatype, total, hit)
end
$stdout.flush
exit!(0)
