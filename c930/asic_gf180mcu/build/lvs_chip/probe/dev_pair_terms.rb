# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# dev_pair_terms.rb -- for one instance, how does each paired device's terminals map?
#
# `net_term_counts.rb` shows equal terminal counts and equal names on both sides of every internal
# net, and the pairs are still Mismatch. That leaves the device pairing: if a layout transistor is
# paired with a schematic transistor whose source and drain are exchanged, every net keeps its
# count and name while each device pair disagrees. This prints the mapping so the difference is a
# number, not an inference.
#
#   klayout -b -r dev_pair_terms.rb -rd file=<report.lvsdb> -rd want=_71769_
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

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-PAIR') unless cp

# Net pairing: layout net name -> schematic net name, from the xref (not from names).
netmap = {}
x.each_net_pair(cp) do |p|
  next unless p.first && p.second
  netmap[nname(p.first)] = nname(p.second)
end

terms = { a: {}, b: {} }
[[cp.first, :a], [cp.second, :b]].each do |circuit, side|
  next unless circuit
  circuit.each_net do |n|
    nm = nname(n)
    n.each_terminal do |t|
      d = t.device
      next unless d
      (terms[side][d.id] ||= {})[t.terminal_id] = nm
    end
  end
end

swap = diff = same = 0
rows = []
x.each_device_pair(cp) do |p|
  next unless p.first && p.second
  b = nname(p.second)
  next unless b.include?(WANT)
  ka = terms[:a][p.first.id] || {}
  kb = terms[:b][p.second.id] || {}
  ids = (ka.keys | kb.keys).sort
  mapped = ids.map { |t| [t, ka[t], kb[t], ka[t] ? netmap[ka[t]] : nil] }
  equal = mapped.all? { |_t, _la, lb, ma| ma == lb }
  s = ids.size == 4 && mapped.all? { |t, _la, lb, ma| ma == kb[({ 0 => 2, 2 => 0, 1 => 1, 3 => 3 }[t])] }
  if equal
    same += 1
  elsif s
    swap += 1
  else
    diff += 1
  end
  rows << [sname(p.status), p.first.device_class.name, b, equal, s,
           mapped.map { |t, la, lb, ma| "#{t}:#{la}=>#{lb}#{ma == lb ? '' : "(#{ma})"}" }.join(' ')]
end
puts "INSTANCE #{WANT} device pairs=#{rows.size} terminals-equal=#{same} pure-SD-swap=#{swap} other=#{diff}"
rows.first(16).each do |st, cls, b, equal, s, map|
  tag = equal ? 'equal' : (s ? 'SD-swap' : 'other')
  puts format('%-9s %-12s %-18s %-8s %s', st, cls, b, tag, map)
end
$stdout.flush
exit!(0)
