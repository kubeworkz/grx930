# GDS identity checks for G0.
# Required -rd values: gds, base, topcell, expected_drops, report.
$stdout.sync = true

gds = $gds
base = $base
topcell = $topcell || "grx930_test_chip"
expected_drops = ($expected_drops || "8168").to_i
report = $report || "/work/build/production/manifests/gds_checks.txt"

raise "missing gds path" if gds.nil? || gds.empty?
raise "missing base path" if base.nil? || base.empty?

layout = RBA::Layout.new
layout.read(gds)
base_layout = RBA::Layout.new
base_layout.read(base)

cell = layout.cell(topcell)
raise "topcell #{topcell} not found; tops=#{layout.top_cells.map(&:name).join(',')}" if cell.nil?
base_cell = base_layout.cell(topcell)
raise "base topcell #{topcell} not found" if base_cell.nil?

dbu = layout.dbu
bb = cell.bbox
die_w = bb.width * dbu
die_h = bb.height * dbu

via2_li = layout.find_layer(38, 0)
base_via2_li = base_layout.find_layer(38, 0)
raise "via2 layer 38/0 missing" if via2_li.nil? || base_via2_li.nil?

via2 = RBA::Region.new(cell.begin_shapes_rec(via2_li))
base_via2 = RBA::Region.new(base_cell.begin_shapes_rec(base_via2_li))
new_via2 = via2 - base_via2

# The ECO uses four Via2 cuts per drop, each 0.26 x 0.26 um.
def count_026(region)
  n = 0
  region.each do |p|
    b = p.bbox
    n += 1 if b.width == 260 && b.height == 260 && p.area == 67_600
  end
  n
end

new_cuts = count_026(new_via2)
drops = new_cuts / 4

# sub_row_300 from build_row_crops.rb: x=3088850, y=2794960, ty=2802960,
# expanded by the same M2 window used by that generator.
row300 = RBA::Region.new(RBA::Box.new(3_088_430, 2_794_510, 3_089_270, 2_803_410))
row300_new = count_026(new_via2 & row300)

lines = []
lines << "TOPCELLS=#{layout.top_cells.map(&:name).join(',')}"
lines << "TOPCELL=#{topcell}"
lines << "DIE_W_UM=#{format('%.3f', die_w)}"
lines << "DIE_H_UM=#{format('%.3f', die_h)}"
lines << "VIA2_NEW_CUTS=#{new_cuts}"
lines << "DROPS=#{drops}"
lines << "EXPECTED_DROPS=#{expected_drops}"
lines << "ROW300_NEW_VIA2_CUTS=#{row300_new}"
failures = []
failures << "die width #{format('%.3f', die_w)} != 3930.000" unless (die_w - 3930.0).abs < 0.001
failures << "die height #{format('%.3f', die_h)} != 5120.000" unless (die_h - 5120.0).abs < 0.001
failures << "drops #{drops} != #{expected_drops}" unless drops == expected_drops
failures << "new via2 cuts #{new_cuts} != 4*#{expected_drops}" unless new_cuts == 4 * expected_drops
failures << "row300 has #{row300_new} new via2 cuts" unless row300_new == 0
lines << "FAILURES=#{failures.join('; ')}"

text = lines.join("\n") + "\n"
puts text
File.write(report, text)
exit(failures.empty? ? 0 : 1)
