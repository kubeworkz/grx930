# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# label_truth.rb -- for one labelled instance, is each layout net name paired with the schematic
# net of the same name?
#
# `label_cell_nets.py` writes `<instance>.<net>` at a point taken from the cell map. If the point
# is right, the layout net carries that name and the comparer should pair it with the schematic
# net of the same name. If the point is on a neighbour's metal, the name is attached to the wrong
# net and the comparer silently ignores the hint -- which looks exactly like "names do not help".
#
#   klayout -b -r label_truth.rb -rd file=<report.lvsdb> -rd want=_71769_ [-rd n=40]
FILE = $file
WANT = ($want || '_71769_').to_s
N = ($n || 40).to_i
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

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-PAIR') unless cp

same = differ = unnamed = 0
rows = []
x.each_net_pair(cp) do |p|
  next unless p.second
  b = nname(p.second)
  next unless b.include?(WANT)
  a = p.first ? nname(p.first) : '(nil)'
  if p.first.nil?
    unnamed += 1
  elsif a == b
    same += 1
  else
    differ += 1
  end
  rows << [sname(p.status), a, b]
end
puts "INSTANCE #{WANT}: pairs=#{rows.size} same-name=#{same} different-name=#{differ} no-layout-net=#{unnamed}"
rows.sort.each { |r| puts format('  %-10s layout=%-24s schematic=%s', *r) if r[1] != r[2] }
rows.each_with_index { |r, i| puts format('  %-10s %-24s %s', *r) if i < N && r[1] == r[2] }
$stdout.flush
exit!(0)
