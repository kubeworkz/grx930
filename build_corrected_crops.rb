$stdout.sync = true
require "fileutils"
GDS = "/work/build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix16.gds"
OUTDIR = "/work/build/lvs_chip/eco_drop_2x2/corrected"
# Surrogate crop: original sites plus replacement clean-row/corridor sites.
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
SITES.each do |name, x, y, ty|
  win = RBA::Box.new(x - 5_000, [y, ty].min - 2_000, x + 5_000, [y, ty].max + 2_000)
  [[34, 0], [36, 0], [42, 0], [35, 0], [38, 0]].each do |ln, dt|
    reg = source_regions[[ln, dt]] & RBA::Region.new(win)
    reg.each { |p| bcell.shapes(bl[[ln, dt]]).insert(p); acell.shapes(al[[ln, dt]]).insert(p) }
  end
  # Real-net landing metal: pad plus a small merge into the existing M1/M3 rows.
  acell.shapes(al[[34, 0]]).insert(RBA::Box.new(x - 450, y - 390, x + 450, y + 390))
  acell.shapes(al[[42, 0]]).insert(RBA::Box.new(x - 450, ty - 400, x + 450, ty + 400))
  # 0.84 um M2 strap, 0.45 um past each via center.
  m2b = [y, ty].min - 450
  m2t = [y, ty].max + 450
  acell.shapes(al[[36, 0]]).insert(RBA::Box.new(x - 420, m2b, x + 420, m2t))
  [-260, 260].each do |dx|
    [-260, 260].each do |dy|
      acell.shapes(al[[35, 0]]).insert(RBA::Box.new(x + dx - 130, y + dy - 130, x + dx + 130, y + dy + 130))
      acell.shapes(al[[38, 0]]).insert(RBA::Box.new(x + dx - 130, ty + dy - 130, x + dx + 130, ty + dy + 130))
    end
  end
  puts "SITE #{name} #{x} #{y} #{ty}"
end
FileUtils.mkdir_p(OUTDIR)
before.write("#{OUTDIR}/corrected_before.gds")
after.write("#{OUTDIR}/corrected_after.gds")
puts "WROTE #{OUTDIR}"
exit! 0
