# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_dev_namecheck.rb -- of the both-sided non-Match device pairs, how many sit on identically
# named nets on every terminal?
#
# With the labelled die the comparer has an instance-qualified name for every cell-internal net
# (133,478 of them, all landing on the net of the same name -- `lvsdb_label_pairs.rb`), so a device
# pair whose four terminals are on nets with equal names on both sides has no connectivity left to
# disagree about. Counting them separates the residue into "equivalent but not rated Match" and a
# genuinely disagreeing remainder, which is what the clock's 36 terminals inherit.
#
#   klayout -b -r lvsdb_dev_namecheck.rb -rd file=<report.lvsdb> [-rd examples=4]
FILE = $file
EXAMPLE = ($examples || 4).to_i

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

# (side, device id) -> { terminal id => [net names on that net] }. A merged layout net can carry
# several labels, so a terminal holds a *set*; equality is set equality.
nets = { a: {}, b: {} }
[[cp.first, :a], [cp.second, :b]].each do |circuit, side|
  next unless circuit
  circuit.each_net do |n|
    nm = nname(n)
    n.each_terminal do |t|
      d = t.device
      next unless d
      ((nets[side][d.id] ||= {})[t.terminal_id] ||= []) << nm
    end
  end
end

# The clock's own terminals, so the count can be split by whether the terminal is a clock terminal.
clk_devs = { a: {}, b: {} }
x.each_net_pair(cp) do |p|
  a = nname(p.first).downcase
  b = nname(p.second).downcase
  next unless a.include?('i_clk') || b.include?('i_clk')
  [[p.first, :a], [p.second, :b]].each do |n, side|
    next unless n
    n.each_terminal do |t|
      d = t.device
      next unless d
      (clk_devs[side][d.id] ||= []) << t.terminal_id
    end
  end
  break
end
puts "clock devices: layout #{clk_devs[:a].size}, schematic #{clk_devs[:b].size}"

tally = Hash.new(0)
by_class = Hash.new(0)
clk_tally = Hash.new(0)
bad = []
x.each_device_pair(cp) do |p|
  next unless p.first && p.second
  next if sname(p.status) == 'Match'
  ka = nets[:a][p.first.id] || {}
  kb = nets[:b][p.second.id] || {}
  ids = ka.keys | kb.keys
  differs = ids.reject { |t| (ka[t] || []).sort == (kb[t] || []).sort }
  cls = (p.first.respond_to?(:device_class) && p.first.device_class) ? p.first.device_class.name : '?'
  key = differs.empty? ? 'all_terminals_equal' : "differs_on_#{differs.size}"
  tally[key] += 1
  by_class[cls] += 1 if differs.empty?
  is_clk = clk_devs[:a][p.first.id] ? true : false
  clk_tally["#{key}#{is_clk ? ' clock' : ''}"] += 1
  if differs.any? && bad.size < EXAMPLE
    t = differs.first
    bad << [p.first.id, cls, differs.size, nname(p.first), nname(p.second),
            "#{t}:#{(ka[t] || []).join(',')} / #{(kb[t] || []).join(',')}"]
  end
end
puts 'BOTH-SIDED NON-MATCH BY TERMINAL NAMES ' + tally.sort_by { |_k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(' ')
puts 'CLOCK TERMINALS BY TERMINAL NAMES ' + clk_tally.sort_by { |_k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(' ')
puts 'ALL-TERMINALS-EQUAL BY DEVICE CLASS ' + by_class.sort_by { |_k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(' ')
bad.each do |id, cls, n, a, b, detail|
  puts format('   %-8s %-14s %d differ  %s <-> %s  [%s]', id, cls, n, a[0, 20], b[0, 20], detail[0, 60])
end
puts format('DONE %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
