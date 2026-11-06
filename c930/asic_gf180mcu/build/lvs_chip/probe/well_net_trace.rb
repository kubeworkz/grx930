# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# well_net_trace.rb -- the unpaired nets behind the bulk mismatches, identified as nets, not names.
#
# `dev_mismatch_cause.rb` grouped by name and reported "45 distinct unpaired layout nets", with
# `$4412` said to span rows 184..1032. A physical net cannot span rows 180 apart, and it does not:
# KLayout does not require net names to be unique (`Netlist::Net` has an id for exactly this
# reason, and this build's Ruby API does not expose it). The same `$4412` is many different nets.
#
# This keys everything on the layout net *object* from the cross-reference, so each row below is
# one physical net: its name (for reading), how many terminals it carries, which device pairs
# depend on it, and which instances it touches.
#
#   klayout -b -r well_net_trace.rb -rd file=<report.lvsdb> -rd out=<txt>
FILE = $file
OUT = $out
abort('usage: -rd file=<report.lvsdb> -rd out=<txt>') unless FILE && OUT

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

def inst_of(name)
  s = name.to_s
  s.include?('.') ? s.split('.', 2).first : '(top)'
end

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-PAIR') unless cp

# Has this layout net a schematic partner? Keyed by object, since names repeat.
partner = {}
x.each_net_pair(cp) { |p| partner[p.first.object_id] = p.second if p.first }

# device id -> { terminal id => net object }
terms = {}
cp.first.each_net do |n|
  n.each_terminal do |t|
    d = t.device
    next unless d
    (terms[d.id] ||= {})[t.terminal_id] = n
  end
end

classes = {}
cp.first.each_device { |d| classes[d.id] = d.device_class.name.to_s }

agg = {}
order = []
x.each_device_pair(cp) do |p|
  next unless p.first && p.second
  next if sname(p.status) == 'Match'
  inst = inst_of(nname(p.second))
  ka = terms[p.first.id] || {}
  seen = {}
  ka.each do |tid, net|
    next if partner[net.object_id]
    a = (agg[net.object_id] ||= { name: nname(net), terms: 0, pairs: 0, inst: {}, cls: Hash.new(0), tids: Hash.new(0) })
    order << net.object_id unless order.include?(net.object_id) || a[:seen]
    a[:terms] += 1
    a[:tids][tid.to_s] += 1
    a[:inst][inst] = true
    a[:cls][classes[p.first.id]] += 1
    seen[net.object_id] = true
  end
  seen.each_key { |k| agg[k][:pairs] += 1 }
end

File.open(OUT, 'w') do |fh|
  fh.puts "net_obj\tname\tterminals\tpairs\tinstances\tdevices\tterminal_ids"
  agg.each do |oid, a|
    fh.puts [oid, a[:name], a[:terms], a[:pairs], a[:inst].keys.sort.join(','),
             a[:cls].sort.map { |k, v| "#{k}=#{v}" }.join(' '),
             a[:tids].sort.map { |k, v| "#{k}=#{v}" }.join(' ')].join("\t")
  end
end

puts "unpaired NET OBJECTS: #{agg.size} (device pairs 752)"
tot = agg.values.map { |a| a[:pairs] }.sum
puts "pair memberships #{tot}"
agg.sort_by { |_k, a| -a[:pairs] }.first(15).each do |_oid, a|
  puts format('  %-12s terms=%-4d pairs=%-3d inst=%s', a[:name], a[:terms], a[:pairs], a[:inst].keys.first(6).join(','))
end
puts "WROTE #{OUT}"
puts format('DONE %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
