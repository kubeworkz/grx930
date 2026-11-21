# GDS identity checks for G0.
# Required -rd values: gds, base, def, expected_drops, report.
# expected_die_w/expected_die_h are optional; when omitted the DEF die is
# reported but not compared, so a new floorplan needs no code change. The old
# row-300 exclusion box was removed with the old floorplan: VDD exclusion is
# enforced by the ECO site list, not by a fixed rectangle.
$stdout.sync = true

gds = $gds
base = $base
def_file = $def
topcell = $topcell || "grx930_test_chip"
raise "missing expected_drops (-rd expected_drops=<N>)" if $expected_drops.nil? || $expected_drops.to_s.empty?
expected_drops = $expected_drops.to_i
expected_die_w = $expected_die_w&.to_f
expected_die_h = $expected_die_h&.to_f
report = $report || "/work/build/production/manifests/gds_checks.txt"

raise "missing gds path" if gds.nil? || gds.empty?
raise "missing base path" if base.nil? || base.empty?
raise "missing def path" if def_file.nil? || def_file.empty?

# Die size comes from the DEF DIEAREA, not the GDS content bounding box.
def_text = File.read(def_file)
units = def_text[/^UNITS\s+DISTANCE\s+MICRONS\s+(\d+)/, 1]
die_match = def_text.match(/^DIEAREA\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)/)
raise "DEF UNITS DISTANCE MICRONS missing" if units.nil?
raise "DEF DIEAREA missing" if die_match.nil?
def_units = units.to_f
die_x1 = die_match[1].to_f
die_y1 = die_match[2].to_f
die_x2 = die_match[3].to_f
die_y2 = die_match[4].to_f
die_w = (die_x2 - die_x1) / def_units
die_h = (die_y2 - die_y1) / def_units

layout = RBA::Layout.new
layout.read(gds)
base_layout = RBA::Layout.new
base_layout.read(base)

cell = layout.cell(topcell)
raise "topcell #{topcell} not found; tops=#{layout.top_cells.map(&:name).join(',')}" if cell.nil?
base_cell = base_layout.cell(topcell)
raise "base topcell #{topcell} not found" if base_cell.nil?

bb = cell.bbox
gds_x1 = bb.left * layout.dbu
gds_y1 = bb.bottom * layout.dbu
gds_x2 = bb.right * layout.dbu
gds_y2 = bb.top * layout.dbu
gds_w = bb.width * layout.dbu
gds_h = bb.height * layout.dbu

via2_li = layout.find_layer(38, 0)
base_via2_li = base_layout.find_layer(38, 0)
raise "via2 layer 38/0 missing" if via2_li.nil? || base_via2_li.nil?

via2 = RBA::Region.new(cell.begin_shapes_rec(via2_li))
base_via2 = RBA::Region.new(base_cell.begin_shapes_rec(base_via2_li))
new_via2 = via2 - base_via2

# Four 0.26-um Via2 cuts per ECO drop.
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

lines = []
lines << "TOPCELLS=#{layout.top_cells.map(&:name).join(',')}"
lines << "TOPCELL=#{topcell}"
lines << "DEF_DIE_UM=#{format('%.3f', die_w)}x#{format('%.3f', die_h)}"
lines << "DEF_DIE_ORIGIN_UM=#{format('%.3f', die_x1 / def_units)},#{format('%.3f', die_y1 / def_units)}"
lines << "GDS_CONTENT_BBOX_UM=#{format('%.3f', gds_w)}x#{format('%.3f', gds_h)}"
lines << "GDS_CONTENT_ORIGIN_UM=#{format('%.3f', gds_x1)},#{format('%.3f', gds_y1)}"
lines << "VIA2_NEW_CUTS=#{new_cuts}"
lines << "DROPS=#{drops}"
lines << "EXPECTED_DROPS=#{expected_drops}"
lines << "EXPECTED_DIE_UM=" + (expected_die_w && expected_die_h ?
  "#{format('%.3f', expected_die_w)}x#{format('%.3f', expected_die_h)}" : "from DEF (not compared)")
failures = []
if expected_die_w && expected_die_h
  failures << "DEF die #{format('%.3f', die_w)}x#{format('%.3f', die_h)} != #{format('%.3f', expected_die_w)}x#{format('%.3f', expected_die_h)}" unless (die_w - expected_die_w).abs < 0.001 && (die_h - expected_die_h).abs < 0.001
end
failures << "GDS content extends outside DEF die" unless gds_x1 >= die_x1 / def_units && gds_y1 >= die_y1 / def_units && gds_x2 <= die_x2 / def_units && gds_y2 <= die_y2 / def_units
failures << "drops #{drops} != #{expected_drops}" unless drops == expected_drops
failures << "new via2 cuts #{new_cuts} != 4*#{expected_drops}" unless new_cuts == 4 * expected_drops
lines << "FAILURES=#{failures.join('; ')}"

text = lines.join("\n") + "\n"
puts text
File.write(report, text)
exit(failures.empty? ? 0 : 1)
