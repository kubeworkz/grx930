# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# Stage 6 GDS writer: insert every 2x2 ECO drop into the pre-ECO GDS with the
# geometry build_row_crops.rb established, and (optionally) emit one DRC crop
# holding a window around *every* site instead of the 13-site representative set.
#
#   klayout -b -r patch_eco_gds.rb -rd gds=pre_eco.gds \
#     -rd sites=eco_sites.csv -rd out=final.gds -rd crop_dir=crop
#
# The site list is the CSV find_eco_sites.py writes: name,x,y,ty,... in GDS dbu
# (1 nm).  The drops are drawn directly on the layers the DRC deck reads, so the
# crop and the full layout carry the same metal.  M1/M3 landings, the 0.84 um M2
# strap and the 2x2 0.26 um cut arrays are placed at the same coordinates as the
# DEF writer, insert_eco_2x2.py.

$stdout.sync = true
require "fileutils"

LAYERS = [[34, 0], [36, 0], [42, 0], [35, 0], [38, 0]].freeze
R_M1 = 450
R_M1Y = 390
R_M3 = 450
R_M3Y = 400
R_M2 = 420
EXT = 450
CUT = 130
OFF = 260

gds_path = $gds
site_path = $sites
out_path = $out
top_name = $top || "grx930_test_chip"
crop_dir = $crop_dir
# pads=all draws the M1/M3 landings everywhere; pads=drawn draws them only where
# find_eco_sites.py reported added metal (m1_added_um2 > 0), so the clipped sites
# get the via cuts and the M2 strap but no synthetic landing.
pads_mode = $pads_mode || "all"
skip_full = $skip_full.to_s == "1"

abort "missing -rd gds=..." if gds_path.nil?
abort "missing -rd sites=..." if site_path.nil?
abort "missing -rd out=..." if out_path.nil?

sites = []
File.foreach(site_path) do |line|
  next if line.start_with?("#") || line.strip.empty?
  field = line.strip.split(",")
  raise "#{site_path}: expected name,x,y,ty" if field.size < 4
  added = field.size > 6 ? field[6].to_f : 0.0
  sites << [field[0], field[1].to_i, field[2].to_i, field[3].to_i, added]
end
raise "#{site_path}: no sites" if sites.empty?

def layer_index(layout, ln, dt)
  li = layout.layer_infos.find { |x| x.layer == ln && x.datatype == dt }
  raise "missing layer #{ln}/#{dt}" if li.nil?
  layout.find_layer(li)
end

# The drop as build_row_crops.rb draws it: 0.90 x 0.78 M1 landing, 0.90 x 0.80
# M3 landing, 0.84 um M2 strap with 0.45 um past each via centre, and two 2x2
# arrays of 0.26 um cuts on 0.52 um centres.
def add_drop(sh1, sh2, sh3, sv1, sv2, x, y, ty, pads)
  if pads
    sh1.insert(RBA::Box.new(x - R_M1, y - R_M1Y, x + R_M1, y + R_M1Y))
    sh3.insert(RBA::Box.new(x - R_M3, ty - R_M3Y, x + R_M3, ty + R_M3Y))
  end
  m2b = [y, ty].min - EXT
  m2t = [y, ty].max + EXT
  sh2.insert(RBA::Box.new(x - R_M2, m2b, x + R_M2, m2t))
  [-OFF, OFF].each do |dx|
    [-OFF, OFF].each do |dy|
      sv1.insert(RBA::Box.new(x + dx - CUT, y + dy - CUT, x + dx + CUT, y + dy + CUT))
      sv2.insert(RBA::Box.new(x + dx - CUT, ty + dy - CUT, x + dx + CUT, ty + dy + CUT))
    end
  end
end

src = RBA::Layout.new
src.read(gds_path)
top = src.cell(top_name)
abort "#{gds_path}: missing top cell #{top_name}" if top.nil?
src_layers = {}
LAYERS.each { |ln, dt| src_layers[[ln, dt]] = layer_index(src, ln, dt) }

if crop_dir
  FileUtils.mkdir_p(crop_dir)
  before = RBA::Layout.new
  before.dbu = src.dbu
  after = RBA::Layout.new
  after.dbu = src.dbu
  bcell = before.create_cell("crop_drc")
  acell = after.create_cell("crop_drc")
  bl = {}
  al = {}
  LAYERS.each do |ln, dt|
    bl[[ln, dt]] = before.layer(ln, dt)
    al[[ln, dt]] = after.layer(ln, dt)
  end
  regions = {}
  LAYERS.each { |ln, dt| regions[[ln, dt]] = RBA::Region.new(top.begin_shapes_rec(src_layers[[ln, dt]])) }
  # Clip against the union of every window once per layer: one scan, not one per
  # site (209 x 5 full-die region intersections take minutes).  DRC only reads the
  # shapes inside the windows, so the grouping does not matter.
  win_union = RBA::Region.new
  sites.each do |_name, x, y, ty, _added|
    win_union.insert(RBA::Box.new(x - 5_000, [y, ty].min - 2_000, x + 5_000, [y, ty].max + 2_000))
  end
  win_union = win_union.merged
  LAYERS.each do |ln, dt|
    (regions[[ln, dt]] & win_union).each do |p|
      bcell.shapes(bl[[ln, dt]]).insert(p)
      acell.shapes(al[[ln, dt]]).insert(p)
    end
  end
  sites.each do |_name, x, y, ty, added|
    pads = pads_mode != "drawn" || added > 0
    add_drop(acell.shapes(al[[34, 0]]), acell.shapes(al[[36, 0]]), acell.shapes(al[[42, 0]]),
             acell.shapes(al[[35, 0]]), acell.shapes(al[[38, 0]]), x, y, ty, pads)
  end
  regions.clear
  before.write(File.join(crop_dir, "all_before.gds"))
  after.write(File.join(crop_dir, "all_after.gds"))
  puts "CROP #{crop_dir}/all_before.gds #{crop_dir}/all_after.gds sites=#{sites.size}"
end

unless skip_full
  sites.each do |_name, x, y, ty, added|
    pads = pads_mode != "drawn" || added > 0
    add_drop(top.shapes(src_layers[[34, 0]]), top.shapes(src_layers[[36, 0]]),
             top.shapes(src_layers[[42, 0]]), top.shapes(src_layers[[35, 0]]),
             top.shapes(src_layers[[38, 0]]), x, y, ty, pads)
  end
  src.write(out_path)
  puts "WROTE #{out_path} sites=#{sites.size} pads=#{pads_mode}"
else
  puts "SKIP_FULL pads=#{pads_mode}"
end
exit! 0
