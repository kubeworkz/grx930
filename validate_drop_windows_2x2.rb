$stdout.sync = true
gds_path = "/work/c930/asic_gf180mcu/build/lvs_chip/fill_regression_tie_final.gds"
gl = RBA::Layout.new
gl.read(gds_path)
top = gl.top_cell
def gidx(gl, ln, dt)
  li = gl.layer_infos.find { |x| x.layer == ln && x.datatype == dt }
  li && gl.find_layer(li)
end
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
by = {}
cp.each_net { |n| by[n.name] = n if n.name; by[n.expanded_name] = n if n.expanded_name }
m1 = l2n.layer_by_index(25)
m2 = l2n.layer_by_index(26)
m3 = l2n.layer_by_index(27)
sub = by["sub"]
vss = by["vss"]
vdd = by["vdd"]
rail = by["$45264"]
abort("missing net") if sub.nil? || vss.nil? || vdd.nil? || rail.nil?
r_sub = l2n.shapes_of_net(sub, m1, true)
r_rail = l2n.shapes_of_net(rail, m1, true)
r_vss = l2n.shapes_of_net(vss, m3, true)
r_vdd = l2n.shapes_of_net(vdd, m3, true)

def strip_centers(region)
  ys = []
  region.each do |p|
    b = p.bbox
    next unless b.width > 100_000 && b.height >= 1_000 && b.height <= 2_000
    ys << ((b.bottom + b.top) / 2)
  end
  ys.uniq.sort
end
vss_strips = strip_centers(r_vss)
vdd_strips = strip_centers(r_vdd)
abort("no strips") if vss_strips.empty? || vdd_strips.empty?
puts "VSS_STRIPS=#{vss_strips.size} VDD_STRIPS=#{vdd_strips.size}"

CELL = 10_000
grid = Hash.new { |h, k| h[k] = [] }
m2.each do |p|
  b = p.bbox
  (b.left / CELL..b.right / CELL).each do |kx|
    (b.bottom / CELL..b.top / CELL).each do |ky|
      grid[[kx, ky]] << [b.left, b.bottom, b.right, b.top]
    end
  end
end
puts "M2_GRID_CELLS=#{grid.size}"

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

# Final 2x2 arrays: H_V via1, V_H via2.
# M2 strap 0.84 um; 0.28 um space each side => 1.40 um keepout.
# M1 pad 0.90 x 0.78; M3 pad 0.90 x 0.80; M2 pad extends 0.45 um past via center.
HALF = 700
PAD_Y = 450
M1_HALF = 450
M1_V = 390
M3_HALF = 450
M3_V = 400

def row_intervals(region, y)
  box = RBA::Box.new(0, y - 200, 4_000_000, y + 200)
  (region & RBA::Region.new(box)).each.map(&:bbox).map { |b| [b.left, b.right] }
end

def legal_at?(x, y, ty, m2grid, r_m1, r_m3)
  lo = [y, ty].min - PAD_Y
  hi = [y, ty].max + PAD_Y
  return false unless m2_free?(m2grid, x, lo, hi, HALF, CELL)
  m1 = (r_m1 & RBA::Region.new(RBA::Box.new(x - M1_HALF, y - M1_V, x + M1_HALF, y + M1_V))).count > 0
  m3 = (r_m3 & RBA::Region.new(RBA::Box.new(x - M3_HALF, ty - M3_V, x + M3_HALF, ty + M3_V))).count > 0
  m1 && m3
end

legal_rows = 0
fail_rows = []
row_y.each_with_index do |y, idx|
  ty = vss_strips.min_by { |s| (s - y).abs }
  found = nil
  row_intervals(r_sub, y).each do |a, b|
    next if b - a < 2 * M1_HALF
    x = a + M1_HALF
    while x <= b - M1_HALF
      if legal_at?(x, y, ty, grid, r_sub, r_vss)
        found = x
        break
      end
      x += 5_000
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
fail_rows.first(30).each { |f| puts "  FAIL y=#{f[0]} idx=#{f[1]}" }

# $45264: require the full 2x2 M1 pad, so scan actual rail coverage.
b = r_rail.bbox
rail_y = (b.bottom + b.top) / 2
ty = vdd_strips.min_by { |s| (s - rail_y).abs }
legal = []
x = b.left + M1_HALF
while x <= b.right - M1_HALF
  legal << x if legal_at?(x, rail_y, ty, grid, r_rail, r_vdd)
  x += 1_000
end
puts "RAIL_BBOX=#{(b.left*0.001).round(3)}..#{(b.right*0.001).round(3)} Y=#{(rail_y*0.001).round(3)} VDD_STRIP=#{(ty*0.001).round(3)}"
puts "45264_LEGAL_X_COUNT=#{legal.size} FIRST=#{(legal.first || 0)*0.001} LAST=#{(legal.last || 0)*0.001}"
if legal.size >= 2
  x1 = legal.first
  x2 = legal.last
  puts "DROP1=#{(x1*0.001).round(3)},#{(rail_y*0.001).round(3)} DROP2=#{(x2*0.001).round(3)},#{(rail_y*0.001).round(3)} SEP=#{((x2-x1)*0.001).round(3)}"
end
