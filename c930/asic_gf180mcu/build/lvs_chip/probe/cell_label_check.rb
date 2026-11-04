# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# cell_label_check.rb -- did the written labels land on the nets they name?
#
# A label is only useful if the netter attaches it to the intended net; a text 1 nm off a metal
# shape names nothing, and one on a neighbour's shape names the wrong net. Both cases are visible in
# a cell comparison of the *labelled* cell: the net pairs carry a name on each side, so the check is
# equality on every internal net, not a count.
#
#   klayout -b -r cell_label_check.rb -rd file=<labelled cell report.lvsdb>
FILE = $file
lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
x = lvs.xref
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

def nname(o)
  return '(nil)' if o.nil?
  return o.expanded_name if o.respond_to?(:expanded_name)
  return o.name if o.respond_to?(:name)
  o.to_s
end

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-PAIR') unless cp
pins = {}
cp.second.each_pin { |pin| pins[pin.name.to_s] = true } if cp.second.respond_to?(:each_pin)

same = differ = unnamed = 0
rows = []
x.each_net_pair(cp) do |p|
  next if p.second.nil?
  name = nname(p.second)
  next if pins[name]
  lay = nname(p.first)
  if lay.start_with?('$')
    unnamed += 1
    rows << ['UNNAMED', lay, name, sname(p.status)]
  elsif lay == name
    same += 1
  else
    differ += 1
    rows << ['DIFFER', lay, name, sname(p.status)]
  end
end
puts "INTERNAL NETS same=#{same} differ=#{differ} unnamed=#{unnamed}"
rows.first(20).each { |r| puts format('  %-8s layout=%-14s schematic=%-14s [%s]', *r) }
$stdout.flush
exit!(0)
