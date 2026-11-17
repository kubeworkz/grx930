$stdout.sync = true
GDS = "/work/build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix16.gds"
layout = RBA::Layout.new
layout.read(GDS)
top = layout.cell("grx930_test_chip")
li = layout.layer_infos.find { |x| x.layer == 36 && x.datatype == 0 }
m2 = RBA::Region.new(top.begin_shapes_rec(layout.find_layer(li)))
box = RBA::Box.new(3_040_000, 2_780_000, 3_100_000, 2_812_000)
m2 = m2 & RBA::Region.new(box)
clear = m2.sized(280)
puts "M2 shapes in scan box=#{m2.count}"
lanes = []
(3_040_000..3_100_000).step(20) do |x|
  strap = RBA::Box.new(x - 420, 2_789_000, x + 420, 2_808_800)
  next if (clear & RBA::Region.new(strap)).area > 0
  lanes << x
end
puts "CLEAR_LANES=#{lanes.size}"
lanes.each_slice(12) { |s| puts s.map { |x| (x * 0.001).round(3) }.join(",") }
exit! 0
