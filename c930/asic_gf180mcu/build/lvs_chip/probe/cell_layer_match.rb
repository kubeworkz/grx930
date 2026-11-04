# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# cell_layer_match.rb -- which lvsdb layer *is* drawn metal1 (or poly2)?
#
# `shapes_of_net` only accepts the LVS data's own layer indexes (`l1`, `l2`, ...), and those carry no
# GDS number. Labelling from whatever layer happened to hold a net's shape put 5 of dffq_1's 12
# labels on other nets: a derived layer is not drawn geometry, so its bbox centre can land on a
# neighbour's metal. The fix is to label only from a layer whose region *is* the drawn conductor --
# region XOR drawn is empty -- which this probe measures.
#
#   klayout -b -r cell_layer_match.rb -rd file=<cell report.lvsdb> -rd cell=<cell> -rd gds=<lib.gds>
#           [-rd gds_layer=34,0]
FILE = $file
CELL = $cell
GDS = $gds
GL = ($gds_layer || '34,0').split(',').map(&:to_i)

lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
lib = RBA::Layout.new
lib.read(GDS)
cell = lib.cell(CELL)
abort("NO-CELL #{CELL}") if cell.nil?
li = lib.find_layer(GL[0], GL[1])
abort("NO-LAYER #{GL.inspect}") if li.nil?
drawn = RBA::Region.new(cell.begin_shapes_rec(li))
puts "drawn #{GL.inspect}: #{drawn.count} shapes area=#{drawn.area} bbox=#{drawn.bbox}"

lvs.layer_names.sort.each do |nm|
  region = lvs.layer_by_name(nm)
  next if region.nil? || region.count.zero?
  same = begin
    region.xor(drawn).is_empty?
  rescue StandardError
    false
  end
  puts format('  %-6s count=%-5d area=%-10d xor_empty=%s', nm, region.count, region.area, same) if same || (region.area - drawn.area).abs < drawn.area / 50
end
$stdout.flush
exit!(0)
