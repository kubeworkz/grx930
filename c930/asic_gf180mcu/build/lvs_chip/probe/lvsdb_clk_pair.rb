# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_clk_pair.rb -- what did the comparison decide about the clock net?
#
# The xref partition on this die is dominated by the unstitched supply (`VDD` is 558 layout
# fragments against one schematic net at these bounds), so the global counts cannot say whether the
# clock -- the net the fill fix was about -- was paired. This walks the top circuit pair and prints
# the status of every net whose name mentions the clock, with the terminal counts on both sides, plus
# the same for the two largest nets so the supply's decision is visible beside it.
#
#   klayout -b -r lvsdb_clk_pair.rb -rd file=<report.lvsdb> [-rd want=i_clk] [-rd examples=8]
FILE = $file
WANT = ($want || 'i_clk').downcase
EXAMPLE = ($examples || 8).to_i

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

def terms(n)
  return 0 if n.nil?
  k = 0
  n.each_terminal { |_t| k += 1 }
  k
rescue StandardError
  -1
end

cp = nil
x.each_circuit_pair { |p| cp = p; break }
unless cp
  puts 'NO-CIRCUIT-PAIR'
  $stdout.flush
  exit!(0)
end
puts "CIRCUIT #{nname(cp.first || cp.second)} [#{sname(cp.status)}]"

rows = []
x.each_net_pair(cp) do |p|
  a = nname(p.first)
  b = nname(p.second)
  ta = terms(p.first)
  tb = terms(p.second)
  rows << [sname(p.status), a, ta, b, tb]
end
puts "NET PAIRS #{rows.size}"

status = Hash.new(0)
rows.each { |r| status[r[0]] += 1 }
puts 'STATUS ' + status.sort_by { |_k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(' ')

puts "== nets mentioning #{WANT}"
hits = rows.select { |_s, a, _ta, b, _tb| a.downcase.include?(WANT) || b.downcase.include?(WANT) }
hits.sort_by { |_s, _a, ta, _b, tb| -([ta, tb].max) }.first(EXAMPLE).each do |s, a, ta, b, tb|
  puts format('CLK %-18s layout=%7d terms %-28s schematic=%7d terms %s', s, ta, a[0, 28], tb, b[0, 28])
end
puts "CLK count=#{hits.size}"

puts '== largest net pairs by terminals'
rows.sort_by { |_s, _a, ta, _b, tb| -([ta, tb].max) }.first(4).each do |s, a, ta, b, tb|
  puts format('BIG %-18s layout=%7d terms %-26s schematic=%7d terms %s', s, ta, a[0, 26], tb, b[0, 26])
end
puts format('DONE %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
