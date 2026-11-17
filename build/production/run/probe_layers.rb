layout = RBA::Layout.new
layout.read($gds)
cell = layout.cell($topcell || "grx930_test_chip")
raise "missing topcell" if cell.nil?
puts "DBU=#{layout.dbu}"
bb = cell.bbox
puts "TOP_BBOX=#{bb.width * layout.dbu}x#{bb.height * layout.dbu} dbu=#{bb.width}x#{bb.height}"
layout.layer_infos.each do |li|
  idx = layout.find_layer(li)
  next if idx.nil?
  reg = RBA::Region.new(cell.begin_shapes_rec(idx))
  next if reg.is_empty?
  b = reg.bbox
  next if b.width < 100_000 && b.height < 100_000
  puts "LAYER=#{li.layer}/#{li.datatype} BBOX_UM=#{format('%.3f', b.width * layout.dbu)}x#{format('%.3f', b.height * layout.dbu)} DBU=#{b.width}x#{b.height}"
end
