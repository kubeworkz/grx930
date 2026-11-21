# Builds the control DEF/GDS pairs for def_gds_checks.rb.
# The pairs are synthetic: they are not the production ECO list. The main pair
# carries all 8,168 approved 2x2 ECO via names at legal sites, with
# M1/M3 landings, an 0.84 um M2 strap, and the real 2x2 Via1/Via2 cut arrays on
# GDS layers 35/0 and 38/0. The GDS is written from the same site table in
# micrometres, independently of the DEF's 2000 dbu/um text, so the checker
# must parse, convert, and XOR two encodings.
#
# Controls written beside it:
# - positive_missing_cuts.gds omits the Via1 cuts at site 0 and the Via2 cuts
#   at site 1, proving the cut check is not vacuous.
# - windowed_final.{def,gds}, windowed_base.{def,gds} and windowed_sites.csv
#   are the windowed pair: the base has smaller landings and strap and no ECO
#   vias, the final carries the ECO geometry, both hold one pre-existing
#   Via1/Via2 array outside every window so the cut layers exist in both
#   streams, and the site list holds one window per drop. Their shapes stay
#   inside the +-1.5 um window.
# - windowed_sites_shift.csv moves site 0 by +5.0 um, so its new geometry falls
#   outside every window and the windowed check must fail.
#
# Run inside the KLayout container:
#   klayout -b -r make_def_gds_positive_fixture.rb \
#     -rd out_dir=/work/build/production/fixtures/def_gds_positive
$stdout.sync = true

out_dir = $out_dir || "/work/build/production/fixtures/def_gds_positive"
Dir.mkdir(out_dir) unless Dir.exist?(out_dir)

DIE_W = 7_864_000
DIE_H = 10_244_000
VIA1 = "Via1_2X2_0_60_10_60_H_V"
VIA2 = "Via2_2X2_0_60_10_60_V_H"
EXPECTED = 8_168
# 2x2 cut array offsets in GDS dbu: 0.26 um cuts on 0.52 um centers.
CUT_BOXES = [
  [-390, -390, -130, -130],
  [130, -390, 390, -130],
  [-390, 130, -130, 390],
  [130, 130, 390, 390],
].freeze

# Per-site geometry in DEF dbu: metal1/metal3 are [half-width, half-height]
# landing rectangles and strap is [half-length, width] of the Metal2 segment.
# The wide set is the production-scale drop. The windowed set nests base inside
# final and stays within the +-1.5 um (1500 GDS dbu) site window, so its delta
# is a frame on every metal and no delta can land outside a window.
GEOM_WIDE = { m1: [900, 780], strap: [2800, 1680], m3: [900, 800] }.freeze
GEOM_WINDOWED_FINAL = { m1: [500, 400], strap: [2000, 600], m3: [500, 450] }.freeze
GEOM_WINDOWED_BASE = { m1: [300, 250], strap: [1600, 400], m3: [300, 300] }.freeze
# Pre-existing via array in GDS dbu, 10 um off the site grid and far from every
# window; present in both windowed streams so the cut layers exist in each.
FIXED_VIA = [1_610_000, 4_410_000].freeze

# 136 x 60 grid plus 8 extras = 8,168 sites. The grid stops at x=2800 um and
# y=1280 um; the extras sit at x=3200..3340 um, y=4000 um.
sites = []
136.times do |col|
  60.times do |row|
    sites << [200_000 + 40_000 * col, 200_000 + 40_000 * row]
  end
end
8.times { |k| sites << [6_400_000 + 40_000 * k, 8_000_000] }
raise "site count #{sites.length} != #{EXPECTED}" unless sites.length == EXPECTED

def_file = File.join(out_dir, "positive.def")
gds_file = File.join(out_dir, "positive.gds")
mismatch_file = File.join(out_dir, "positive_missing_cuts.gds")
win_final_def = File.join(out_dir, "windowed_final.def")
win_final_gds = File.join(out_dir, "windowed_final.gds")
win_base_def = File.join(out_dir, "windowed_base.def")
win_base_gds = File.join(out_dir, "windowed_base.gds")
win_sites_csv = File.join(out_dir, "windowed_sites.csv")
win_shift_csv = File.join(out_dir, "windowed_sites_shift.csv")

def write_def(path, sites, geom = GEOM_WIDE, vias: true)
  m1x, m1y = geom[:m1]
  strap_x, strap_w = geom[:strap]
  m3x, m3y = geom[:m3]
  File.open(path, "w") do |f|
    f.puts "VERSION 5.8 ;"
    f.puts "DIVIDERCHAR \"/\" ;"
    f.puts "BUSBITCHARS \"[]\" ;"
    f.puts "DESIGN grx930_test_chip ;"
    f.puts "UNITS DISTANCE MICRONS 2000 ;"
    f.puts "DIEAREA ( 0 0 ) ( #{DIE_W} #{DIE_H} ) ;"
    f.puts "SPECIALNETS #{sites.length + 1} ;"
    f.puts "- VDD ( * VDD ) + USE POWER"
    f.puts "  + ROUTED Metal4 ( 3000000 9000000 ) RECT ( -1000 -1000 1000 1000 )"
    f.puts "    NEW Metal5 ( 3000000 9000000 ) RECT ( -1200 -1200 1200 1200 )"
    f.puts "  ;"
    sites.each_with_index do |(cx, cy), i|
      f.puts "- VSS_#{i} ( * VSS ) + USE GROUND"
      f.puts "  + ROUTED Metal1 ( #{cx} #{cy} ) RECT ( -#{m1x} -#{m1y} #{m1x} #{m1y} )"
      f.puts "    NEW Metal2 #{strap_w} ( #{cx - strap_x} #{cy} ) ( #{cx + strap_x} #{cy} )"
      f.puts "    NEW Metal3 ( #{cx} #{cy} ) RECT ( -#{m3x} -#{m3y} #{m3x} #{m3y} )"
      if vias
        f.puts "  + ROUTED Metal2 ( #{cx} #{cy} ) #{VIA1}"
        f.puts "    NEW Metal3 ( #{cx} #{cy} ) #{VIA2}"
      end
      f.puts "  ;"
    end
    f.puts "END SPECIALNETS"
    f.puts "END DESIGN"
  end
  path
end

def write_gds(path, sites, geom = GEOM_WIDE, omit: {}, cuts: true, fixed_vias: false)
  layout = RBA::Layout.new
  layout.dbu = 0.001
  cell = layout.create_cell("grx930_test_chip")
  m1 = layout.layer(34, 0)
  v1 = layout.layer(35, 0)
  m2 = layout.layer(36, 0)
  v2 = layout.layer(38, 0)
  m3 = layout.layer(42, 0)
  m4 = layout.layer(46, 0)
  m5 = layout.layer(81, 0)

  m1x, m1y = geom[:m1]
  strap_x, strap_w = geom[:strap]
  m3x, m3y = geom[:m3]
  sites.each_with_index do |(cx, cy), i|
    ax = cx / 2
    ay = cy / 2
    cell.shapes(m1).insert(RBA::Box.new((cx - m1x) / 2, (cy - m1y) / 2,
                                        (cx + m1x) / 2, (cy + m1y) / 2))
    cell.shapes(m2).insert(RBA::Box.new((cx - strap_x - strap_w / 2) / 2,
                                        (cy - strap_w / 2) / 2,
                                        (cx + strap_x + strap_w / 2) / 2,
                                        (cy + strap_w / 2) / 2))
    cell.shapes(m3).insert(RBA::Box.new((cx - m3x) / 2, (cy - m3y) / 2,
                                        (cx + m3x) / 2, (cy + m3y) / 2))
    if cuts && omit[i] != :via1
      CUT_BOXES.each do |x0, y0, x1, y1|
        cell.shapes(v1).insert(RBA::Box.new(ax + x0, ay + y0, ax + x1, ay + y1))
      end
    end
    if cuts && omit[i] != :via2
      CUT_BOXES.each do |x0, y0, x1, y1|
        cell.shapes(v2).insert(RBA::Box.new(ax + x0, ay + y0, ax + x1, ay + y1))
      end
    end
  end
  if fixed_vias
    fx, fy = FIXED_VIA
    CUT_BOXES.each do |x0, y0, x1, y1|
      cell.shapes(v1).insert(RBA::Box.new(fx + x0, fy + y0, fx + x1, fy + y1))
      cell.shapes(v2).insert(RBA::Box.new(fx + x0, fy + y0, fx + x1, fy + y1))
    end
  end
  # One M4/M5 pair so those GDS layers are present for the XOR comparison.
  cell.shapes(m4).insert(RBA::Box.new(1_500_000 - 500, 4_500_000 - 500,
                                      1_500_000 + 500, 4_500_000 + 500))
  cell.shapes(m5).insert(RBA::Box.new(1_500_000 - 600, 4_500_000 - 600,
                                      1_500_000 + 600, 4_500_000 + 600))
  layout.write(path)
  path
end

write_def(def_file, sites)
write_gds(gds_file, sites)
write_gds(mismatch_file, sites, omit: { 0 => :via1, 1 => :via2 })

# Windowed pair: the base and final differ only inside the site windows.
write_def(win_final_def, sites, GEOM_WINDOWED_FINAL)
write_gds(win_final_gds, sites, GEOM_WINDOWED_FINAL, fixed_vias: true)
write_def(win_base_def, sites, GEOM_WINDOWED_BASE, vias: false)
write_gds(win_base_gds, sites, GEOM_WINDOWED_BASE, cuts: false, fixed_vias: true)

# Window lists are in GDS dbu; the site table is in DEF dbu (2000/um).
[win_sites_csv, win_shift_csv].each do |path|
  File.open(path, "w") do |f|
    f.puts "# name,x,y,ty"
    sites.each_with_index do |(cx, cy), i|
      x = cx / 2 + (path == win_shift_csv && i.zero? ? 5000 : 0)
      f.puts format("site_%04d,%d,%d,%d", i, x, cy / 2, cy / 2)
    end
  end
end

[def_file, gds_file, mismatch_file, win_final_def, win_final_gds,
 win_base_def, win_base_gds, win_sites_csv, win_shift_csv].each do |path|
  puts "WROTE #{path} (#{File.size(path)} bytes)"
end
puts "SITES=#{sites.length} VIA1=#{sites.length} VIA2=#{sites.length}"
puts "SHIFTED_SITE=site_0000 +5000 dbu"
