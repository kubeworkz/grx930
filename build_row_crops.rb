$stdout.sync = true
require "fileutils"
GDS = "/work/build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix16.gds"
OUTDIR = "/work/build/lvs_chip/eco_drop_2x2/row_corrected"
# [name, x, y, ty, landing_bridge_x0]  Original rows only; bridge_x0 extends
# M1/M3 from the real row/strip edge to the clean-x landing pad.
SITES = [
  ["sub_row_0",   2_727_650,   442_985,   462_960, nil],
  ["sub_row_50",  1_971_500,   834_960,   842_960, nil],
  ["sub_row_100", 1_970_530, 1_226_960, 1_222_960, nil],
  ["sub_row_150", 2_716_450, 1_618_960, 1_622_960, nil],
  ["sub_row_200", 3_088_850, 2_010_960, 2_002_960, nil],
  ["sub_row_250", 2_717_000, 2_402_800, 2_402_960, nil],
  ["sub_row_350", 2_728_330, 3_186_800, 3_182_960, 2_722_500],
  ["sub_row_400", 1_975_690, 3_578_800, 3_582_960, 1_971_300],
  ["sub_row_450", 1_970_530, 3_970_960, 3_962_960, nil],
  ["sub_row_500", 1_970_530, 4_362_960, 4_362_960, nil],
  ["sub_row_540", 1_966_050, 4_676_536, 4_662_960, nil],
  ["rail_left",   1_488_000, 2_979_500, 2_972_960, nil],
  ["rail_right",  1_651_600, 2_973_500, 2_972_960, nil]
].freeze

src = RBA::Layout.new
src.read(GDS)
stop = src.cell("grx930_test_chip")
raise "missing top" if stop.nil?
def layer_index(layout, ln, dt)
  li = layout.layer_infos.find { |x| x.layer == ln && x.datatype == dt }
  raise "missing layer #{ln}/#{dt}" unless li
  layout.find_layer(li)
end
before = RBA::Layout.new
before.dbu = src.dbu
bcell = before.create_cell("crop_drc")
after = RBA::Layout.new
after.dbu = src.dbu
acell = after.create_cell("crop_drc")
bl = {}
al = {}
[[34, 0], [36, 0], [42, 0], [35, 0], [38, 0]].each do |ln, dt|
  bl[[ln, dt]] = before.layer(ln, dt)
  al[[ln, dt]] = after.layer(ln, dt)
end
source_regions = {}
[[34, 0], [36, 0], [42, 0], [35, 0], [38, 0]].each do |ln, dt|
  source_regions[[ln, dt]] = RBA::Region.new(stop.begin_shapes_rec(layer_index(src, ln, dt)))
end
SITES.each do |name, x, y, ty, bridge_x0, right_ext|
  win = RBA::Box.new([x, bridge_x0 || x].min - 5_000, [y, ty].min - 2_000,
                     x + 5_000, [y, ty].max + 2_000)
  [[34, 0], [36, 0], [42, 0], [35, 0], [38, 0]].each do |ln, dt|
    reg = source_regions[[ln, dt]] & RBA::Region.new(win)
    reg.each { |p| bcell.shapes(bl[[ln, dt]]).insert(p); acell.shapes(al[[ln, dt]]).insert(p) }
  end
  # Landing pad plus explicit M1/M3 extension to the original-net edge.
  acell.shapes(al[[34, 0]]).insert(RBA::Box.new(x - 450, y - 390, x + 450, y + 390))
  acell.shapes(al[[42, 0]]).insert(RBA::Box.new(x - 450, ty - 400, x + 450, ty + 400))
  if bridge_x0
    acell.shapes(al[[34, 0]]).insert(RBA::Box.new(bridge_x0, y - 390, x - 450, y + 390))
    acell.shapes(al[[42, 0]]).insert(RBA::Box.new(bridge_x0, ty - 400, x - 450, ty + 400))
  end
  if right_ext
    acell.shapes(al[[34, 0]]).insert(RBA::Box.new(x + 450, y - 800, x + 450 + right_ext, y + 390))
    acell.shapes(al[[42, 0]]).insert(RBA::Box.new(x + 450, ty - 800, x + 450 + right_ext, ty + 400))
  end
  m2b = [y, ty].min - 450
  m2t = [y, ty].max + 450
  acell.shapes(al[[36, 0]]).insert(RBA::Box.new(x - 420, m2b, x + 420, m2t))
  [-260, 260].each do |dx|
    [-260, 260].each do |dy|
      acell.shapes(al[[35, 0]]).insert(RBA::Box.new(x + dx - 130, y + dy - 130, x + dx + 130, y + dy + 130))
      acell.shapes(al[[38, 0]]).insert(RBA::Box.new(x + dx - 130, ty + dy - 130, x + dx + 130, ty + dy + 130))
    end
  end
  puts "SITE #{name} #{x} #{y} #{ty} bridge=#{bridge_x0 || '-'} right_ext=#{right_ext || '-'}"
end
FileUtils.mkdir_p(OUTDIR)
before.write("#{OUTDIR}/row_before.gds")
after.write("#{OUTDIR}/row_after.gds")
puts "WROTE #{OUTDIR}"
exit! 0
