$stdout.sync = true
GDS = "/work/build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix16.gds"
layout = RBA::Layout.new
layout.read(GDS)
top = layout.cell("grx930_test_chip")
raise "missing top" if top.nil?
box = RBA::Box.new(3_070_000, 2_790_000, 3_085_000, 2_806_000)
puts "NEAREST VDD LABEL TO (3076.23,2797.48)"
layout.layer_indexes.each do |li|
  info = layout.get_info(li)
  next unless info.datatype == 10 || info.datatype == 11 || info.datatype == 1
  begin
    texts = RBA::Texts.new(top.begin_shapes_rec(li))
  rescue StandardError
    next
  end
  best = nil
  texts.each do |t|
    next unless t.string.upcase == "VDD"
    next unless t.x >= box.left && t.x <= box.right && t.y >= box.bottom && t.y <= box.top
    d = Math.hypot(t.x - 3_076_230, t.y - 2_797_480)
    best = [d, t.x, t.y] if best.nil? || d < best[0]
  end
  next if best.nil?
  puts "LAYER #{info.layer}/#{info.datatype} distance=#{best[0] * 0.001} um VDD at #{best[1] * 0.001},#{best[2] * 0.001}"
end
puts "DONE"
exit! 0
