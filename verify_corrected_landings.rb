$stdout.sync = true
GDS = "/work/build/lvs_chip/eco_drop_2x2/corrected/corrected_before.gds"
SITES = [
  ["sub_row_0",   2_727_650,   442_985,   462_960],
  ["sub_row_50_resite", 1_970_530, 1_226_960, 1_222_960],
  ["sub_row_100", 1_970_530, 1_226_960, 1_222_960],
  ["sub_row_150", 2_716_450, 1_618_960, 1_622_960],
  ["sub_row_200", 3_088_850, 2_010_960, 2_002_960],
  ["sub_row_250_resite", 1_970_530, 4_362_960, 4_362_960],
  ["sub_row_300_resite", 1_970_530, 3_970_960, 3_962_960],
  ["sub_row_350_resite", 2_727_650, 442_985, 462_960],
  ["sub_row_400_resite", 2_716_450, 1_618_960, 1_622_960],
  ["sub_row_450", 1_970_530, 3_970_960, 3_962_960],
  ["sub_row_500", 1_970_530, 4_362_960, 4_362_960],
  ["sub_row_540", 1_966_050, 4_676_536, 4_662_960],
  ["rail_left",   1_488_000, 2_979_500, 2_972_960],
  ["rail_right",  1_651_600, 2_973_500, 2_972_960]
].freeze
layout = RBA::Layout.new
layout.read(GDS)
cell = layout.cell("crop_drc")
raise "missing crop_drc" if cell.nil?
def reg(layout, cell, ln, dt)
  li = layout.layer_infos.find { |x| x.layer == ln && x.datatype == dt }
  raise "missing layer #{ln}/#{dt}" unless li
  RBA::Region.new(cell.begin_shapes_rec(layout.find_layer(li)))
end
m1 = reg(layout, cell, 34, 0)
m3 = reg(layout, cell, 42, 0)
m2 = reg(layout, cell, 36, 0)
failures = []
SITES.each do |name, x, y, ty|
  p1 = RBA::Box.new(x - 450, y - 390, x + 450, y + 390)
  p3 = RBA::Box.new(x - 450, ty - 400, x + 450, ty + 400)
  s2 = RBA::Box.new(x - 420, [y, ty].min - 450, x + 420, [y, ty].max + 450)
  a1 = (m1 & RBA::Region.new(p1)).area
  a3 = (m3 & RBA::Region.new(p3)).area
  a2 = (m2 & RBA::Region.new(s2)).area
  pad1 = p1.area
  pad3 = p3.area
  c1 = (a1.to_f / pad1 * 100).round(1)
  c3 = (a3.to_f / pad3 * 100).round(1)
  puts "LAND #{name} M1_overlap=#{c1}% M3_overlap=#{c3}% M2_foreign_overlap_area=#{a2}"
  failures << "#{name}: M1 pad not connected" if a1 <= 0
  failures << "#{name}: M3 pad not connected" if a3 <= 0
  failures << "#{name}: M2 strap intersects existing M2" if a2 > 0
end
if failures.empty?
  puts "LANDING_CHECK PASS"
else
  puts "LANDING_CHECK FAIL"
  failures.each { |f| puts "  #{f}" }
  exit 1
end
exit! 0
