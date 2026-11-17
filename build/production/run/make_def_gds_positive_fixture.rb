# Builds the positive-control DEF/GDS pair for def_gds_checks.rb.
# The pair is synthetic: it is not the production ECO list. It carries all
# 8,168 approved 2x2 ECO via names at legal non-row-300 sites, with M1/M3
# landings, an 0.84 um M2 strap, and the real 2x2 Via1/Via2 cut arrays on GDS
# layers 35/0 and 38/0. The GDS is written from the same site table in
# micrometres, independently of the DEF's 2000 dbu/um text, so the checker
# must parse, convert, and XOR two encodings.
#
# Two negative pairs are written beside it:
# - positive_missing_cuts.gds omits the Via1 cuts at site 0 and the Via2 cuts
#   at site 1, proving the cut check is not vacuous.
# - row300_via2.{def,gds} moves one drop into the row-300 exclusion box,
#   keeping both via counts at 8,168, so the row-300 rule is the only failure.
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

# 136 x 60 grid plus 8 extras = 8,168 sites. The grid stops at x=2800 um and
# y=1280 um; the extras sit at x=3200..3340 um, y=4000 um. None intersects the
# row-300 exclusion box (3088.43..3089.27 um, 2794.51..2803.41 um).
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
row300_def = File.join(out_dir, "row300_via2.def")
row300_gds = File.join(out_dir, "row300_via2.gds")

def write_def(path, sites)
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
      f.puts "  + ROUTED Metal1 ( #{cx} #{cy} ) RECT ( -900 -780 900 780 )"
      f.puts "    NEW Metal2 1680 ( #{cx - 2800} #{cy} ) ( #{cx + 2800} #{cy} )"
      f.puts "    NEW Metal3 ( #{cx} #{cy} ) RECT ( -900 -800 900 800 )"
      f.puts "  + ROUTED Metal2 ( #{cx} #{cy} ) #{VIA1}"
      f.puts "    NEW Metal3 ( #{cx} #{cy} ) #{VIA2}"
      f.puts "  ;"
    end
    f.puts "END SPECIALNETS"
    f.puts "END DESIGN"
  end
  path
end

def write_gds(path, sites, omit = {})
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

  sites.each_with_index do |(cx, cy), i|
    ax = cx / 2
    ay = cy / 2
    cell.shapes(m1).insert(RBA::Box.new((cx - 900) / 2, (cy - 780) / 2,
                                        (cx + 900) / 2, (cy + 780) / 2))
    cell.shapes(m2).insert(RBA::Box.new((cx - 3640) / 2, (cy - 840) / 2,
                                        (cx + 3640) / 2, (cy + 840) / 2))
    cell.shapes(m3).insert(RBA::Box.new((cx - 900) / 2, (cy - 800) / 2,
                                        (cx + 900) / 2, (cy + 800) / 2))
    unless omit[i] == :via1
      CUT_BOXES.each do |x0, y0, x1, y1|
        cell.shapes(v1).insert(RBA::Box.new(ax + x0, ay + y0, ax + x1, ay + y1))
      end
    end
    unless omit[i] == :via2
      CUT_BOXES.each do |x0, y0, x1, y1|
        cell.shapes(v2).insert(RBA::Box.new(ax + x0, ay + y0, ax + x1, ay + y1))
      end
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
write_gds(mismatch_file, sites, 0 => :via1, 1 => :via2)

# Row-300 negative pair: one drop moves to the center of the exclusion box.
# Both via counts stay at 8,168, so only the row-300 rule may fail.
ROW300_VIA2 = [3_088_850, 2_798_960]
row300_sites = sites.dup
row300_sites[0] = ROW300_VIA2
write_def(row300_def, row300_sites)
write_gds(row300_gds, row300_sites)

[def_file, gds_file, mismatch_file, row300_def, row300_gds].each do |path|
  puts "WROTE #{path} (#{File.size(path)} bytes)"
end
puts "SITES=#{sites.length} VIA1=#{sites.length} VIA2=#{sites.length}"
puts "ROW300_ANCHOR=#{ROW300_VIA2.join(',')}"
