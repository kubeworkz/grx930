# LEGACY single-via probe.  Do not use for the final ECO; the final geometry is
# validated by validate_drop_windows_2x2.rb and build_crop_drc_real.rb.
$stdout.sync = true
gds_path = "/work/c930/asic_gf180mcu/build/lvs_chip/fill_regression_tie_final.gds"
gl = RBA::Layout.new
gl.read(gds_path)
top = gl.top_cell
def gidx(gl, ln, dt)
  li = gl.layer_infos.find { |x| x.layer == ln && x.datatype == dt }
  li && gl.find_layer(li)
end
# VSS row centers from M1 labels.
ys = []
RBA::Texts.new(top.begin_shapes_rec(gidx(gl, 34, 10))).each do |t|
  ys << t.y if t.string.upcase == "VSS"
end
ys.sort!
rows = []
ys.each do |y|
  if rows.empty? || y - rows[-1][:ymax] > 300
    rows << { sum: 0, n: 0, ymax: y }
  end
  r = rows[-1]
  r[:sum] += y
  r[:n] += 1
  r[:ymax] = y
end
row_y = rows.map { |r| (r[:sum] / r[:n].to_f).round }
puts "VSS_ROWS=#{row_y.size}"

l2n = RBA::LayoutToNetlist.new
l2n.read("/scripts/chip.l2n")
cp = nil
l2n.netlist.each_circuit { |c| cp = c if c.name == "grx930_test_chip" }
by_name = {}
cp.each_net { |n| by_name[n.name] = n if n.name; by_name[n.expanded_name] = n if n.expanded_name }
m1 = l2n.layer_by_index(25)
m2 = l2n.layer_by_index(26)
m3 = l2n.layer_by_index(27)
sub = by_name["sub"]
vss = by_name["vss"]
vdd = by_name["vdd"]
rail = by_name["$45264"]
abort("missing paired net") if sub.nil? || vss.nil? || vdd.nil? || rail.nil?
r_sub = l2n.shapes_of_net(sub, m1, true)
r_rail = l2n.shapes_of_net(rail, m1, true)
r_vss_m3 = l2n.shapes_of_net(vss, m3, true)
r_vdd_m3 = l2n.shapes_of_net(vdd, m3, true)
def strip_centers(region)
  ys = []
  region.each do |p|
    b = p.bbox
    next unless b.width > 100_000 && b.height >= 1_000 && b.height <= 2_000
    ys << ((b.bottom + b.top) / 2)
  end
  ys.uniq.sort
end
vss_strips = strip_centers(r_vss_m3)
vdd_strips = strip_centers(r_vdd_m3)
abort("no VSS strips") if vss_strips.empty?
abort("no VDD strips") if vdd_strips.empty?
puts "VSS_STRIPS=#{vss_strips.size} #{vss_strips.first*gl.dbu}..#{vss_strips.last*gl.dbu}"
puts "VDD_STRIPS=#{vdd_strips.size} #{vdd_strips.first*gl.dbu}..#{vdd_strips.last*gl.dbu}"

CELL = 10_000
m2grid = Hash.new { |h, k| h[k] = [] }
m2.each do |p|
  b = p.bbox
  (b.left / CELL..b.right / CELL).each do |kx|
    (b.bottom / CELL..b.top / CELL).each do |ky|
      m2grid[[kx, ky]] << [b.left, b.bottom, b.right, b.top]
    end
  end
end
puts "M2_GRID_CELLS=#{m2grid.size}"

def m2_free?(grid, x, y0, y1, half, cell)
  x0 = (x - half) / cell
  x1 = (x + half) / cell
  cy0 = y0 / cell
  cy1 = y1 / cell
  (x0..x1).each do |kx|
    (cy0..cy1).each do |ky|
      grid[[kx, ky]].each do |b|
        return false if b[0] <= x + half && x - half <= b[2] && b[1] <= y1 && y0 <= b[3]
      end
    end
  end
  true
end

# Conservative envelope: 0.40 um M2, 0.28 um space each side, 0.07 um via enclosure.
HALF = 480 # 0.48 um in nm
PAD = 200 # 0.2 um margin for M1/M3 landing
def row_intervals(region, y, dbu)
  box = RBA::Box.new(0, y - 200, 4_000_000, y + 200)
  rr = region & RBA::Region.new(box)
  ints = []
  rr.each do |p|
    b = p.bbox
    ints << [b.left, b.right]
  end
  ints
end

def nearest_strip(y, strips)
  strips.min_by { |s| (s - y).abs }
end

def legal_at?(x, y, ty, m2grid, r_m3, dbu)
  return false if m2_free?(m2grid, x, [y, ty].min - 200, [y, ty].max + 200, HALF, CELL) == false
  # M3 target presence: 0.4 um x 1.6 um strip
  box = RBA::Box.new(x - 200, ty - 800, x + 200, ty + 800)
  (r_m3 & RBA::Region.new(box)).count > 0
end

legal_rows = 0
fail_rows = []
row_y.each_with_index do |y, idx|
  ints = row_intervals(r_sub, y, gl.dbu)
  ty = nearest_strip(y, vss_strips)
  found = nil
  ints.each do |a, b|
    next if b - a < 2 * PAD + 400
    x = a + PAD + 200
    while x <= b - PAD - 200
      if legal_at?(x, y, ty, m2grid, r_vss_m3, gl.dbu)
        found = x
        break
      end
      x += 5_000 # 5 um
    end
    break if found
  end
  if found
    legal_rows += 1
  else
    fail_rows << [(y * gl.dbu).round(3), idx]
  end
  puts "ROW_PROGRESS=#{idx + 1}" if (idx + 1) % 100 == 0
end
puts "SUB_ROWS_TOTAL=#{row_y.size} SUB_LEGAL_ROWS=#{legal_rows} SUB_FAIL_ROWS=#{fail_rows.size}"
fail_rows.first(20).each { |f| puts "  FAIL y=#{f[0]} idx=#{f[1]}" }

# $45264: find all legal windows, choose up to two ends.
b = r_rail.bbox
rail_y = (b.bottom + b.top) / 2
ty = nearest_strip(rail_y, vdd_strips)
legal_x = []
x = b.left + PAD + 200
while x <= b.right - PAD - 200
  if legal_at?(x, rail_y, ty, m2grid, r_vdd_m3, gl.dbu)
    legal_x << x
  end
  x += 1_000
end
puts "45264_LEGAL_X_COUNT=#{legal_x.size} FIRST=#{(legal_x.first || 0)*gl.dbu} LAST=#{(legal_x.last || 0)*gl.dbu}"
