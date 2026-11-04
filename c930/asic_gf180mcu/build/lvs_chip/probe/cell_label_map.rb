# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# cell_label_map.rb -- turn a cell-level LVS pairing into label positions for the cell's internal nets.
#
# The die run leaves 242 device pairs at `Mismatch` on internal cell nets (`ncki`, `cki`, `net0`..
# `net8`, `int04`, ...). Those nets carry no name in the layout: the DEF labels routed nets only, and
# a cell's internal nets are never routed. probe/cell_label_lvs.sh compares each such cell on its
# own, where the deck resolves it exactly, so its lvsdb carries a verified layout-net ->
# schematic-net pairing for the cell's interior.
#
# Two facts decide how a position is chosen, both measured on dffq_1:
#   * `shapes_of_net` accepts only the LVS data's own layers (`l1`, `l2`, ... from `layer_names`); an
#     index from the internal layout is rejected ("Non-hierarchical layers cannot be used"), and
#     those names carry no GDS number;
#   * a position taken from *any* layer that holds the net is not safe: 5 of the first 12 labels
#     landed on neighbouring nets, because a derived layer's shape is not drawn geometry. The layer
#     used here is the one whose region XOR drawn metal1 is empty (`l13` on dffq_1), so its shapes
#     *are* the net's drawn metal -- and the point is confirmed inside the polygon before it is used.
#
#   klayout -b -r cell_label_map.rb -rd file=<cell report.lvsdb> -rd cell=<cell> \
#           -rd gds=<library.gds> [-rd out=<map.json>]
FILE = $file
CELL = $cell
GDS = $gds
OUT = $out
abort('usage: -rd file=<report.lvsdb> -rd cell=<name> -rd gds=<library.gds> [-rd out=map.json]') \
  unless FILE && CELL && GDS

# Drawn conductor -> the label layer the deck reads for it (rule_decks/layers_definitions.lvs).
LABEL_OF = { [34, 0] => [34, 10], [30, 0] => [30, 10], [36, 0] => [36, 10],
             [42, 0] => [42, 10], [46, 0] => [46, 10], [81, 0] => [81, 10] }.freeze
ORDER = [[34, 0], [30, 0], [36, 0], [42, 0], [46, 0], [81, 0]].freeze

def nname(o)
  return '(nil)' if o.nil?
  return o.expanded_name if o.respond_to?(:expanded_name)
  return o.name if o.respond_to?(:name)
  o.to_s
end

t0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
x = lvs.xref
abort('NO-XREF') unless x
XA = RBA::NetlistCrossReference

def sname(s)
  return 'Match' if s == XA::Match
  return 'MatchWithWarning' if s == XA::MatchWithWarning
  return 'Mismatch' if s == XA::Mismatch
  return 'NoMatch' if s == XA::NoMatch
  return 'Skipped' if s == XA::Skipped
  return 'None' if s == XA::None
  s.to_s
end

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-CIRCUIT-PAIR') unless cp
lay_cc = cp.first
sch_cc = cp.second
abort('NO-BOTH-SIDES') unless lay_cc && sch_cc
puts "CIRCUIT #{nname(lay_cc)} [#{sname(cp.status)}]"
pins = {}
sch_cc.each_pin { |pin| pins[pin.name.to_s] = true } if sch_cc.respond_to?(:each_pin)
puts "PINS #{pins.size}"

# Drawn conductors come from the library GDS: the lvsdb's internal layout keeps only the deck's
# reduced layer set (measured on dffq_1: 21/0, 30/0, 33/0, 34/10, 204/0 -- no 34/0).
lib = RBA::Layout.new
lib.read(GDS)
cell = lib.cell(CELL)
abort("NO-CELL #{CELL} in #{GDS}") if cell.nil?
drawn = {}
ORDER.each do |gds|
  li = lib.find_layer(gds[0], gds[1])
  next if li.nil?
  r = RBA::Region.new(cell.begin_shapes_rec(li))
  next if r.count.zero?
  drawn[gds] = r
end
abort("NO-DRAWN-CONDUCTOR in #{CELL}") if drawn.empty?
puts "DRAWN #{drawn.keys.sort.inspect} dbu=#{lib.dbu}"

# The LVS layer that *is* each drawn conductor: XOR empty. Non-matching layers are not candidates --
# their shapes merely overlap the conductor, and a position taken from one can name a neighbour.
names = lvs.layer_names.sort
on_layer = {}
ORDER.each do |gds|
  r = drawn[gds]
  next if r.nil?
  hit = names.find do |nm|
    reg = lvs.layer_by_name(nm)
    next false if reg.nil? || reg.count.zero?
    begin
      reg.xor(r).is_empty?
    rescue StandardError
      false
    end
  end
  on_layer[gds] = [hit, lvs.layer_by_name(hit)] if hit
end
puts 'MATCHED ' + on_layer.map { |gds, (nm, _)| "#{gds.inspect}=#{nm}" }.join(' ')

def inside_point(poly, n = 6)
  bb = poly.bbox
  probe_poly = RBA::Region.new(poly)
  n.times do |i|
    n.times do |j|
      x = bb.left + ((bb.width - 1) * i) / (n - 1.0)
      y = bb.bottom + ((bb.height - 1) * j) / (n - 1.0)
      pt = RBA::Point.new(x.round, y.round)
      box = RBA::Region.new(RBA::Box.new(pt.x - 1, pt.y - 1, pt.x + 1, pt.y + 1))
      return pt unless probe_poly.and(box).is_empty?
    end
  end
  nil
end

# Metal1 first: the deck has a label layer per conductor and all of them work, but a metal label is
# what a routed net carries too, so the layout keeps one naming style. Poly is the fallback.
def place(net, lvs, on_layer, accept)
  accept.each do |gds|
    nm, region = on_layer[gds]
    next if region.nil?
    shapes = begin
      lvs.shapes_of_net(net, region)
    rescue StandardError
      nil
    end
    next if shapes.nil? || shapes.count.zero?
    shapes.each do |poly|
      pt = inside_point(poly)
      next if pt.nil?
      return { 'layer' => LABEL_OF[gds], 'metal' => gds, 'x' => pt.x, 'y' => pt.y }
    end
  end
  nil
end

nets = {}
skipped = []
candidates = 0
x.each_net_pair(cp) do |p|
  next unless p.first && p.second && sname(p.status) == 'Match'
  name = nname(p.second)
  next if pins[name]
  lay_name = p.first.name.to_s
  next unless lay_name.empty? || lay_name.start_with?('$')
  candidates += 1
  hit = place(p.first, lvs, on_layer, [[34, 0]]) || place(p.first, lvs, on_layer, ORDER)
  if hit
    hit['schematic'] = name
    nets[name] = hit
  else
    skipped << name
  end
end
puts "INTERNAL NETS paired-and-unnamed #{candidates}, placed #{nets.size}, skipped #{skipped.size}"
puts "SKIPPED #{skipped.sort.join(' ')}" unless skipped.empty?
nets.sort.each do |k, v|
  puts format('  %-8s on %-9s -> label %-9s (%d,%d)', k, v['metal'].inspect, v['layer'].inspect, v['x'], v['y'])
end

if OUT
  require 'json'
  File.write(OUT, JSON.pretty_generate({ 'cell' => CELL, 'dbu' => lib.dbu, 'nets' => nets }))
  puts "WROTE #{OUT}"
end
puts format('DONE %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
