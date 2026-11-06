# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# net_term_counts.rb -- for one instance's net pairs, how many device terminals does each side carry?
#
# `label_truth.rb` shows a labelled layout net paired with the schematic net of the *same name*
# and still at Mismatch. A net pair with equal terminal sets would be Match; a pair whose layout
# side carries extra terminals is a merged net (a real connectivity difference at die level, e.g.
# diffusion shared across a cell boundary). Equal counts with unequal device classes point at a
# device pairing problem instead.
#
#   klayout -b -r net_term_counts.rb -rd file=<report.lvsdb> -rd want=_71769_
FILE = $file
WANT = ($want || '_71769_').to_s
abort('usage: -rd file=<report.lvsdb> [-rd want=<instance prefix>]') unless FILE

lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
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

def census(net)
  n = 0
  by = Hash.new(0)
  return [0, '{}'] if net.nil?
  net.each_terminal do |t|
    n += 1
    d = t.device
    by[d && d.device_class ? d.device_class.name : '?'] += 1
  end
  [n, by.sort.to_h.inspect]
end

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-PAIR') unless cp

rows = []
x.each_net_pair(cp) do |p|
  next unless p.second
  b = nname(p.second)
  next unless b.include?(WANT)
  a = p.first ? nname(p.first) : '(nil)'
  ca, da = census(p.first)
  cb, db = census(p.second)
  rows << [sname(p.status), a, b, ca, cb, da, db]
end
puts "INSTANCE #{WANT} net pairs=#{rows.size}"
rows.sort.each do |st, a, b, ca, cb, da, db|
  flag = ca == cb ? '' : '  <-- terminal counts differ'
  puts format('%-9s %-24s %-22s layout=%2d %s  schematic=%2d %s%s', st, a, b, ca, da, cb, db, flag)
end
same = rows.count { |r| r[1] == r[2] }
diff = rows.count { |r| r[3] != r[4] }
puts "same-name=#{same} terminal-count-differ=#{diff}"
$stdout.flush
exit!(0)
