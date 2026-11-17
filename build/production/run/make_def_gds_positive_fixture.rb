# Builds the positive-control DEF/GDS pair for def_gds_checks.rb.
# The pair is synthetic: it is not the production ECO list. It carries all
# 8,168 approved 2x2 ECO via names at legal non-row-300 sites, with M1/M3
# landings and an 0.84 um M2 strap. The GDS is written from the same site
# table in micrometres, independently of the DEF's 2000 dbu/um text, so the
# checker must parse, convert, and XOR two encodings.
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

File.open(def_file, "w") do |f|
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

# GDS side: 1000 dbu/um, so every DEF coordinate is halved. The M2 strap is
# the 1680-dbu (0.84 um) route widened by half-width 840 around its endpoints.
layout = RBA::Layout.new
layout.dbu = 0.001
cell = layout.create_cell("grx930_test_chip")
m1 = layout.layer(34, 0)
m2 = layout.layer(36, 0)
m3 = layout.layer(42, 0)
m4 = layout.layer(46, 0)
m5 = layout.layer(81, 0)

sites.each do |cx, cy|
  cell.shapes(m1).insert(RBA::Box.new((cx - 900) / 2, (cy - 780) / 2,
                                      (cx + 900) / 2, (cy + 780) / 2))
  cell.shapes(m2).insert(RBA::Box.new((cx - 3640) / 2, (cy - 840) / 2,
                                      (cx + 3640) / 2, (cy + 840) / 2))
  cell.shapes(m3).insert(RBA::Box.new((cx - 900) / 2, (cy - 800) / 2,
                                      (cx + 900) / 2, (cy + 800) / 2))
end
# One M4/M5 pair so those GDS layers are present for the XOR comparison.
cell.shapes(m4).insert(RBA::Box.new(1_500_000 - 500, 4_500_000 - 500,
                                    1_500_000 + 500, 4_500_000 + 500))
cell.shapes(m5).insert(RBA::Box.new(1_500_000 - 600, 4_500_000 - 600,
                                    1_500_000 + 600, 4_500_000 + 600))

layout.write(gds_file)
puts "WROTE #{def_file} (#{File.size(def_file)} bytes)"
puts "WROTE #{gds_file} (#{File.size(gds_file)} bytes)"
puts "SITES=#{sites.length} VIA1=#{sites.length} VIA2=#{sites.length}"
