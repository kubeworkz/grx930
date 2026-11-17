$stdout.sync = true
base = "/work/build/lvs_chip/eco_drop_2x2/row_corrected"
b = RBA::Layout.new
b.read("#{base}/row_before.gds")
a = RBA::Layout.new
a.read("#{base}/row_after.gds")
bc = b.cell("crop_drc")
ac = a.cell("crop_drc")
def reg(layout, cell, ln, dt)
  RBA::Region.new(cell.begin_shapes_rec(layout.layer(ln, dt)))
end
bm1 = reg(b, bc, 34, 0); bm2 = reg(b, bc, 36, 0); bm3 = reg(b, bc, 42, 0)
am1 = reg(a, ac, 34, 0); am2 = reg(a, ac, 36, 0); am3 = reg(a, ac, 42, 0)
x = 3_076_080; y = 2_794_960; ty = 2_802_960
m1_pad = RBA::Region.new(RBA::Box.new(x - 450, y - 390, x + 450, y + 390))
m1_ext = RBA::Region.new(RBA::Box.new(x - 645, y - 390, x - 450, y + 390))
m3_pad = RBA::Region.new(RBA::Box.new(x - 450, ty - 400, x + 450, ty + 400))
puts "M1 pad area=#{m1_pad.area} actual_overlap=#{(m1_pad & bm1).area}"
puts "M1 extension area=#{m1_ext.area} actual_overlap=#{(m1_ext & bm1).area}"
puts "M3 pad area=#{m3_pad.area} actual_overlap=#{(m3_pad & bm3).area}"
m2b = y - 450
m2t = ty + 450
h1 = y + 1_340
h2 = ty - 3_160
xr = x + 1_120
segs = {
  "v0" => RBA::Box.new(x - 420, m2b, x + 420, h1 + 420),
  "h1" => RBA::Box.new(x - 420, h1 - 420, xr + 420, h1 + 420),
  "v1" => RBA::Box.new(xr - 420, h1, xr + 420, h2),
  "h2" => RBA::Box.new(x - 420, h2 - 420, xr + 420, h2 + 420),
  "v2" => RBA::Box.new(x - 420, h2, x + 420, m2t)
}
total = 0
segs.each do |name, box|
  reg = RBA::Region.new(box)
  ov = (reg & bm2).area
  total += ov
  puts "M2 #{name} bbox=#{box.left * 0.001},#{box.bottom * 0.001},#{box.right * 0.001},#{box.top * 0.001} foreign_overlap=#{ov}"
end
puts "M2 dogleg total_foreign_overlap=#{total}"
puts "M2 left_gap=#{(x - 420 - 3_075_380) * 0.001} um"
puts "M2 right_gap=#{(3_076_780 - (x + 420)) * 0.001} um"
exit! 0
