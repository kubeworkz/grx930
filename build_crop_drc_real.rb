$stdout.sync = true
require "fileutils"
# Use the latest available full-layout GDS in this checkout.  The selected
# fix70 file is absent; fix16 has the same power rails at the drop sites.
GDS = "/work/build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix16.gds"
OUTDIR = "/work/build/lvs_chip/eco_drop_2x2"
SITES = [
  ["sub_row_0",   2_727_650,   442_985,   462_960],
  ["sub_row_50",  1_970_530,   834_960,   842_960],
  ["sub_row_100", 1_970_530, 1_226_960, 1_222_960],
  ["sub_row_150", 2_716_450, 1_618_960, 1_622_960],
  ["sub_row_200", 3_088_850, 2_010_960, 2_002_960],
  ["sub_row_250", 2_716_450, 2_402_960, 2_402_960],
  ["sub_row_300", 3_088_850, 2_794_960, 2_802_960],
  ["sub_row_350", 2_724_290, 3_186_961, 3_182_960],
  ["sub_row_400", 1_970_530, 3_578_960, 3_582_960],
  ["sub_row_450", 1_970_530, 3_970_960, 3_962_960],
  ["sub_row_500", 1_970_530, 4_362_960, 4_362_960],
  ["sub_row_540", 1_966_050, 4_676_536, 4_662_960],
  ["rail_left",   1_487_970, 2_979_200, 2_972_960],
  ["rail_right",  1_651_970, 2_979_200, 2_972_960]
].freeze

src = RBA::Layout.new
src.read(GDS)
stop = src.cell("grx930_test_chip")
raise "missing grx930_test_chip" if stop.nil?
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
m1l = before.layer(34, 0)
m2l = before.layer(36, 0)
m3l = before.layer(42, 0)
v1l = before.layer(35, 0)
v2l = before.layer(38, 0)
am1 = after.layer(34, 0)
am2 = after.layer(36, 0)
am3 = after.layer(42, 0)
av1 = after.layer(35, 0)
av2 = after.layer(38, 0)

# Extract each source layer once; intersecting a full-die Region per site is
# much cheaper than rebuilding the recursive shape iterator 70 times.
source_regions = {}
[[34, 0], [36, 0], [42, 0], [35, 0], [38, 0]].each do |ln, dt|
  idx = layer_index(src, ln, dt)
  source_regions[[ln, dt]] = RBA::Region.new(stop.begin_shapes_rec(idx))
end

SITES.each do |name, x, y, ty|
  x0 = x - 5_000
  x1 = x + 5_000
  y0 = [y, ty].min - 2_000
  y1 = [y, ty].max + 2_000
  win = RBA::Box.new(x0, y0, x1, y1)
  { m1: [34, 0, m1l, am1], m2: [36, 0, m2l, am2], m3: [42, 0, m3l, am3],
    v1: [35, 0, v1l, av1], v2: [38, 0, v2l, av2] }.each do |_k, v|
    ln, dt, bl, al = v
    reg = source_regions[[ln, dt]] & RBA::Region.new(win)
    reg.each { |p| bcell.shapes(bl).insert(p); acell.shapes(al).insert(p) }
  end

  # Add the final 2x2-array drop (M2 strap 0.84 um).  Do not add new M1/M3
  # landing pads: the existing sub/VSS rows already cover the via array, and
  # synthetic pads created false M1.2a edges against neighboring real metal.
  m2b = [y, ty].min - 450
  m2t = [y, ty].max + 450
  acell.shapes(am2).insert(RBA::Box.new(x - 420, m2b, x + 420, m2t))
  [-260, 260].each do |dx|
    [-260, 260].each do |dy|
      acell.shapes(av1).insert(RBA::Box.new(x + dx - 130, y + dy - 130, x + dx + 130, y + dy + 130))
      acell.shapes(av2).insert(RBA::Box.new(x + dx - 130, ty + dy - 130, x + dx + 130, ty + dy + 130))
    end
  end
end
FileUtils.mkdir_p(OUTDIR)
before.write("#{OUTDIR}/crop_before.gds")
after.write("#{OUTDIR}/crop_after.gds")
puts "WROTE #{OUTDIR}/crop_before.gds #{OUTDIR}/crop_after.gds SITES=#{SITES.size}"
exit! 0
