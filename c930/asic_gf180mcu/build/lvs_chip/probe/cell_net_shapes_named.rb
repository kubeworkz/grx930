# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# cell_net_shapes_named.rb -- net shapes through the named layers the LVS data carries.
#
# The engine exposes `layer_names`, `layer_index` and `layer_by_name` on the LVS data, and
# `shapes_of_net` wants a region built from one of *its* layers -- which is why an internal-layout
# index failed with "Non-hierarchical layers cannot be used in netlist extraction". This resolves
# the LVS data's own layer names and prints, per layer, how many shapes the wanted net has there,
# then checks each resulting point against the drawn layers of the input GDS.
#
#   klayout -b -r cell_net_shapes_named.rb -rd file=<cell report.lvsdb> [-rd want=NCKI]
FILE = $file
WANT = ($want || 'NCKI').to_s.upcase
DRAWN = { [34, 0] => [34, 10], [30, 0] => [30, 10], [36, 0] => [36, 10],
          [42, 0] => [42, 10], [46, 0] => [46, 10], [81, 0] => [81, 10] }.freeze

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
i_cell = lvs.internal_top_cell
i_lay = lvs.internal_layout
puts "net #{WANT} -> layout #{nname(net)} terminals=#{net.terminal_count} cell=#{i_cell.name}"

# Drawn layers available in the internal layout, by GDS number.
idx = {}
i_lay.layer_indexes.each do |li|
  info = i_lay.get_info(li)
  next if info.nil? || info.layer < 0 || info.datatype < 0
  idx[[info.layer, info.datatype]] = li
end
puts "DRAWN #{idx.keys.sort.inspect}"
drawn_regions = {}
idx.each { |gds, li| drawn_regions[gds] = RBA::Region.new(i_cell.begin_shapes_rec(li)) }

names = lvs.layer_names
puts "LAYER NAMES #{names.size}"
names.sort.each do |nm|
  region = lvs.layer_by_name(nm)
  next if region.nil?
  li = nm.sub('l', '').to_i
  next if region.count.zero?
  got = begin
    lvs.shapes_of_net(net, region)
  rescue StandardError => e
    "ERR #{e.message[0, 55]}"
  end
  next if got == 0
  if got.is_a?(String)
    puts format('  %-6s index %3d cell_shapes=%-6d %s', nm, li, region.count, got)
    next
  end
  pt = nil
  got.each do |poly|
    bb = poly.bbox
    c = bb.center
    if RBA::Region.new(poly).contains?(c)
      pt = c
      break
    end
  end
  where = 'no-point'
  if pt
    hit = drawn_regions.find { |_gds, r| r.count > 0 && r.contains?(pt) }
    where = hit ? hit[0].inspect : 'not-on-drawn'
  end
  puts format('  %-6s index %3d cell_shapes=%-6d net_shapes=%-4d point=%s on=%s',
              nm, li, region.count, got.count, pt.nil? ? 'nil' : "(#{pt.x},#{pt.y})", where)
end
$stdout.flush
exit!(0)
