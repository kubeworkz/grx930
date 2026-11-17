$stdout.sync = true
GDS = "/work/build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix16.gds"
layout = RBA::Layout.new
layout.read(GDS)
top = layout.cell("grx930_test_chip")
raise "missing top" if top.nil?
def idx(layout, ln, dt)
  li = layout.layer_infos.find { |x| x.layer == ln && x.datatype == dt }
  raise "missing #{ln}/#{dt}" unless li
  layout.find_layer(li)
end
def shapes(layout, top, ln, dt, box)
  RBA::Region.new(top.begin_shapes_rec(idx(layout, ln, dt))) & RBA::Region.new(box)
end
box = RBA::Box.new(3_070_000, 2_790_000, 3_100_000, 2_808_000)
{ "M1" => [34, 0], "M2" => [36, 0], "M3" => [42, 0], "V1" => [35, 0], "V2" => [38, 0] }.each do |name, (ln, dt)|
  puts "#{name}"
  shapes(layout, top, ln, dt, box).each do |p|
    b = p.bbox
    puts "  #{b.left * 0.001},#{b.bottom * 0.001},#{b.right * 0.001},#{b.top * 0.001}"
  end
end
exit! 0
