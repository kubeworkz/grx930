# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_mismatch_cells.rb -- which cells and which internal nets do the mismatched device pairs sit in?
#
# The stitched die leaves 242 both-sided device pairs at `Mismatch`, all with identical parameters, and
# their terminal nets are the difference. Before any labelling can be planned, this counts *where*
# they are: the schematic device name carries its instance (`_75713_._TN13`), so grouping by instance
# says how many cell types are involved, and the net names on both sides say which internal nets are
# unlabelled in the layout.
#
#   klayout -b -r lvsdb_mismatch_cells.rb -rd file=<report.lvsdb> [-rd examples=10]
FILE = $file
EXAMPLE = ($examples || 10).to_i

t0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
puts format('READ %.1f s', Time.now - t0)
x = lvs.xref
abort('NO-XREF') unless x
X = RBA::NetlistCrossReference

def sname(s)
  return 'Match' if s == X::Match
  return 'MatchWithWarning' if s == X::MatchWithWarning
  return 'Mismatch' if s == X::Mismatch
  return 'NoMatch' if s == X::NoMatch
  return 'Skipped' if s == X::Skipped
  return 'None' if s == X::None
  s.to_s
end

def nname(o)
  return '(nil)' if o.nil?
  return o.expanded_name if o.respond_to?(:expanded_name)
  return o.name if o.respond_to?(:name)
  o.to_s
end

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-CIRCUIT-PAIR') unless cp

# terminal id -> net name, per side, by walking each net's terminals
nets = { a: {}, b: {} }
[[cp.first, :a], [cp.second, :b]].each do |circuit, side|
  next unless circuit
  circuit.each_net do |n|
    nm = nname(n)
    n.each_terminal do |t|
      d = t.device
      next unless d
      (nets[side][d.id] ||= {})[t.terminal_id] = nm
    end
  end
end

by_instance = Hash.new(0)
by_net = Hash.new(0)
unnamed = 0
pairs = 0
x.each_device_pair(cp) do |p|
  next unless p.first && p.second && sname(p.status) != 'Match'
  pairs += 1
  sn = nname(p.second)
  inst = sn.include?('.') ? sn.split('.').first : '(top)'
  by_instance[inst] += 1
  ka = nets[:a][p.first.id] || {}
  kb = nets[:b][p.second.id] || {}
  (ka.keys | kb.keys).each do |tid|
    a = ka[tid].to_s
    b = kb[tid].to_s
    unnamed += 1 if a.start_with?('$')
    by_net["#{a} <-> #{b}"] += 1
  end
end

puts "MISMATCHED PAIRS #{pairs}"
puts "INSTANCES #{by_instance.size}"
by_instance.sort_by { |_k, v| -v }.first(EXAMPLE).each { |k, v| puts format('  %-14s %d devices', k, v) }
puts "NET PAIRS ON THOSE TERMINALS #{by_net.size}, terminals whose layout net is unnamed: #{unnamed}"
by_net.sort_by { |_k, v| -v }.first(EXAMPLE * 2).each { |k, v| puts format('  %-46s %d', k, v) }
puts format('DONE %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
