# DEF/GDS consistency checks for G0.
# Required -rd values: gds, def, topcell, expected_drops, report.
# The DEF's own NETS/SPECIALNETS routing is rebuilt as top-level metal and
# XORed against the frozen GDS. The 8,168 ECO drops must be present as the
# approved 2x2 Via1/Via2 names, and no Via2 cut may overlap the row-300
# exclusion box; an anchor outside the box is not enough if its cuts intrude.
$stdout.sync = true

gds = $gds
def_file = $def
topcell = $topcell || "grx930_test_chip"
expected_drops = ($expected_drops || "8168").to_i
report = $report || "/work/build/production/manifests/def_gds_checks.txt"

raise "missing gds path" if gds.nil? || gds.empty?
raise "missing DEF path" if def_file.nil? || def_file.empty?

# DEF layer name -> PDK GDS layer. Coordinates are converted from DEF units
# (2000/um) to the GDS' 0.001 um dbu by dividing by two.
LAYERS = {
  "Metal1" => [5, 0, 34, 0],
  "Metal2" => [7, 0, 36, 0],
  "Metal3" => [9, 0, 42, 0],
  "Metal4" => [11, 0, 46, 0],
  "Metal5" => [13, 0, 81, 0],
}.freeze
WIDTHS = {
  "Metal1" => 460,   # 0.230 um at 2000 dbu/um
  "Metal2" => 560,   # 0.280 um
  "Metal3" => 560,
  "Metal4" => 560,
  "Metal5" => 880,   # 0.440 um
}.freeze

VIA1 = "Via1_2X2_0_60_10_60_H_V"
VIA2 = "Via2_2X2_0_60_10_60_V_H"
# GDS cut layers for the approved 2x2 arrays (GF180MCU: Via1 35/0, Via2 38/0).
VIA_CUT_LAYER = { VIA1 => [35, 0], VIA2 => [38, 0] }.freeze
# 2x2 cut array: 0.26 um cuts on 0.52 um centers, in GDS dbu (0.001 um).
CUT_BOXES = [
  [-390, -390, -130, -130],
  [130, -390, 390, -130],
  [-390, 130, -130, 390],
  [130, 130, 390, 390],
].freeze
# The same array in DEF units (2000 dbu/um), for the row-300 area rule.
CUT_BOXES_DEF = CUT_BOXES.map { |box| box.map { |v| v * 2 } }.freeze
ROW300_X0 = 3_088_430
ROW300_Y0 = 2_794_510
ROW300_X1 = 3_089_270
ROW300_Y1 = 2_803_410

POINT_RE = /\(\s*(\*|-?\d+)\s+(\*|-?\d+)\s*(?:-?\d+)?\s*\)/
RECT_RE = /RECT\s*\(\s*(-?\d+)\s+(-?\d+)\s*(-?\d+)\s*(-?\d+)\s*\)/
ROUTE_RE = /(ROUTED|NEW|FIXED|COVER|NOSHIELD)\s+([A-Za-z][0-9A-Za-z]*)/
TOKEN_RE = /RECT\s*\(\s*-?\d+\s+-?\d+\s+-?\d+\s+-?\d+\s*\)|\(\s*(?:\*|-?\d+)\s+(?:\*|-?\d+)\s*(?:-?\d+)?\s*\)|[A-Za-z_][0-9A-Za-z_]*/

boxes = Hash.new { |h, k| h[k] = [] }
via1 = 0
via2 = 0
eco_via1 = []
eco_via2 = []
row300_via2 = 0
row300_anchor_via2 = 0
section = nil
layer = nil
width = nil
pts = []
last = nil

def add_box(boxes, layer, x0, y0, x1, y1)
  boxes[layer] << [x0, y0, x1, y1]
end

def add_segment(boxes, layer, x0, y0, x1, y1, w)
  h = w / 2
  add_box(boxes, layer,
          [x0, x1].min - h, [y0, y1].min - h,
          [x0, x1].max + h, [y0, y1].max + h)
end

# True when any of the four Via2 cuts of the array overlaps the row-300 box
# with positive area. Touching an edge is not an overlap.
def row300_cut_overlap?(x, y)
  CUT_BOXES_DEF.each do |x0, y0, x1, y1|
    bx0 = x + x0
    bx1 = x + x1
    by0 = y + y0
    by1 = y + y1
    return true if bx0 < ROW300_X1 && ROW300_X0 < bx1 &&
                   by0 < ROW300_Y1 && ROW300_Y0 < by1
  end
  false
end

File.foreach(def_file) do |line|
  s = line.strip
  if s.start_with?("SPECIALNETS ") || s.start_with?("NETS ")
    section = :nets
    layer = nil
    width = nil
    pts = []
    last = nil
    next
  end
  if s.start_with?("END SPECIALNETS") || s.start_with?("END NETS")
    section = nil
    next
  end
  next unless section == :nets
  if s.start_with?("- ")
    layer = nil
    width = nil
    pts = []
    last = nil
    next
  end

  body = s.start_with?("+") ? s[1..].strip : s
  if (m = ROUTE_RE.match(body))
    layer = m[2]
    rest = body[m.end(0)..] || ""
    width = nil
    if (w = rest.match(/\A\s*(\d+)\s*(.*)\z/))
      width = w[1].to_i
      rest = w[2]
    end
    rest = rest.sub(/\A\s*\+\s*SHAPE\s+\w+\s*/, "")
    pts = []
    last = nil
  elsif layer.nil?
    next
  else
    rest = body
  end

  head = rest.split(";", 2)[0]
  pos = 0
  head.scan(TOKEN_RE) do |tok|
    m = Regexp.last_match
    gap = head[pos...m.begin(0)]
    raise "unreadable DEF routing token #{gap.inspect}" unless gap.strip.empty?
    pos = m.end(0)
    if (r = RECT_RE.match(tok))
      raise "RECT without one anchor" unless last && pts.length == 1
      dx1, dy1, dx2, dy2 = r.captures.map(&:to_i)
      raise "RECT with no area" unless dx2 > dx1 && dy2 > dy1
      add_box(boxes, layer, last[0] + dx1, last[1] + dy1,
              last[0] + dx2, last[1] + dy2)
      pts = []
      last = nil
      next
    end
    if tok.start_with?("(")
      a, b = POINT_RE.match(tok).captures
      if a == "*" || b == "*"
        raise "`*` without previous point" unless last
        x = a == "*" ? last[0] : a.to_i
        y = b == "*" ? last[1] : b.to_i
      else
        x = a.to_i
        y = b.to_i
      end
      if pts.any?
        x0, y0 = pts[-1]
        w = width || WIDTHS[layer]
        raise "no width for #{layer}" unless w
        add_segment(boxes, layer, x0, y0, x, y, w)
      end
      pts << [x, y]
      last = [x, y]
      next
    end

    if tok == VIA1
      raise "#{VIA1} has no anchor point" unless last
      via1 += 1
      eco_via1 << last
    elsif tok == VIA2
      raise "#{VIA2} has no anchor point" unless last
      via2 += 1
      eco_via2 << last
      if last[0] >= ROW300_X0 && last[0] <= ROW300_X1 &&
         last[1] >= ROW300_Y0 && last[1] <= ROW300_Y1
        row300_anchor_via2 += 1
      end
      row300_via2 += 1 if row300_cut_overlap?(last[0], last[1])
    end
    pts = []
    last = nil
  end
  raise "trailing DEF routing text #{head[pos..].inspect}" unless head[pos..].strip.empty?
end

gds_layout = RBA::Layout.new
gds_layout.read(gds)
gds_cell = gds_layout.cell(topcell)
raise "topcell #{topcell} not found in GDS" if gds_cell.nil?

lines = []
failures = []

# Expected cut geometry, anchored at the DEF via points. Each 2x2 array is
# compared only inside its own 0.78 um window so unrelated GDS vias are not
# mistaken for ECO drops.
cut_expected = {}
[VIA1, VIA2].each do |name|
  expected = RBA::Region.new
  windows = RBA::Region.new
  anchors = name == VIA1 ? eco_via1 : eco_via2
  anchors.each do |x, y|
    unless x.even? && y.even?
      failures << "#{name}: anchor #{x},#{y} is off the GDS 0.001 um grid"
      next
    end
    cx = x / 2
    cy = y / 2
    CUT_BOXES.each do |x0, y0, x1, y1|
      expected.insert(RBA::Box.new(cx + x0, cy + y0, cx + x1, cy + y1))
    end
    windows.insert(RBA::Box.new(cx - 390, cy - 390, cx + 390, cy + 390))
  end
  cut_expected[name] = [expected, windows]
end

LAYERS.each do |name, (_dl, _dd, gl, gd)|
  def_region = RBA::Region.new
  boxes[name].each do |x0, y0, x1, y1|
    # DEF units -> GDS dbu, exact because both are integer grids.
    def_region.insert(RBA::Box.new(x0 / 2, y0 / 2, x1 / 2, y1 / 2))
  end
  gds_li = gds_layout.find_layer(RBA::LayerInfo.new(gl, gd))
  if gds_li.nil?
    failures << "#{name}: missing GDS layer #{gl}/#{gd}"
    next
  end
  gds_region = RBA::Region.new(gds_cell.shapes(gds_li))
  xor_region = def_region ^ gds_region
  lines << "DEF_#{name}_SHAPES=#{def_region.count}"
  lines << "GDS_#{name}_SHAPES=#{gds_region.count}"
  lines << "XOR_#{name}_DBU2=#{xor_region.area}"
  failures << "#{name}: DEF/GDS top-level XOR is #{xor_region.area} dbu2" unless xor_region.area == 0
end

VIA_CUT_LAYER.each do |name, (gl, gd)|
  gds_li = gds_layout.find_layer(RBA::LayerInfo.new(gl, gd))
  if gds_li.nil?
    failures << "#{name}: missing GDS cut layer #{gl}/#{gd}"
    next
  end
  gds_cut = RBA::Region.new(gds_cell.shapes(gds_li))
  expected, windows = cut_expected[name]
  observed = gds_cut & windows
  xor = observed ^ expected
  lines << "GDS_#{name}_CUTS=#{observed.count}"
  lines << "XOR_#{name}_CUT_DBU2=#{xor.area}"
  unless xor.area == 0
    failures << "#{name}: GDS cuts do not match the 2x2 array at every DEF anchor (XOR #{xor.area} dbu2)"
  end
end

lines << "ECO_#{VIA1}=#{via1}"
lines << "ECO_#{VIA2}=#{via2}"
lines << "EXPECTED_DROPS=#{expected_drops}"
lines << "ROW300_#{VIA2}=#{row300_via2}"
lines << "ROW300_#{VIA2}_ANCHORS_INSIDE=#{row300_anchor_via2}"
failures << "Via1_2X2 drops #{via1} != #{expected_drops}" unless via1 == expected_drops
failures << "Via2_2X2 drops #{via2} != #{expected_drops}" unless via2 == expected_drops
failures << "row300 has #{row300_via2} Via2_2X2 drops with cuts overlapping the exclusion box" unless row300_via2 == 0

lines << "FAILURES=#{failures.join('; ')}"
text = lines.join("\n") + "\n"
puts text
File.write(report, text)
exit(failures.empty? ? 0 : 1)
