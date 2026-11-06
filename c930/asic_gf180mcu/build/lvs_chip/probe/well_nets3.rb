# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# well_nets3.rb -- the nets with no schematic partner, identified by their terminal sets.
#
# Neither Ruby `object_id` nor `other_net_for` gives a usable net identity here (the first splits
# one net into many, the second answers nil for every net). A net *is* its set of terminals, so
# that set is the identity: `each_net_pair` names the 50 nets with no partner (p.second nil), and
# each one's sorted (device id, terminal id) list is its key.
#
# The key is the signature's `hash`, not the array. The supply nets carry over a million terminals,
# and hashing such an array on every terminal lookup is quadratic in practice (measured: a first
# attempt ran past six minutes without reaching the comparison). A 64-bit digest per net, computed
# once, makes each lookup an integer.
#
#   klayout -b -r well_nets3.rb -rd file=<report.lvsdb> -rd out=<tsv>
FILE = $file
OUT = $out
abort('usage: -rd file=<report.lvsdb> -rd out=<tsv>') unless FILE && OUT

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

def sig_hash(net)
  s = []
  net.each_terminal { |t| s << [t.device.id, t.terminal_id] }
  s.sort.hash
end

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-PAIR') unless cp

# Pass A -- the 50 nets with no schematic partner, keyed by signature digest.
pairs = []
x.each_net_pair(cp) { |p| pairs << [p.first, p.second] }
unpaired = {}
pairs.each { |a, b| unpaired[sig_hash(a)] = { name: nname(a) } if a && b.nil? }
puts "unpaired nets by signature: #{unpaired.size} (xref a-only should be 50)"

# Pass B -- instance of each paired layout device.
inst = {}
x.each_device_pair(cp) { |p| inst[p.first.id] = inst_of(nname(p.second)) if p.first && p.second }

# Pass C -- terminal key -> signature digest.
term_sig = {}
dev_terms = Hash.new { |h, k| h[k] = [] }
cp.first.each_net do |n|
  s = sig_hash(n)
  n.each_terminal do |t|
    term_sig[[t.device.id, t.terminal_id]] = s
    dev_terms[t.device.id] << t.terminal_id
  end
end

classes = {}
cp.first.each_device { |d| classes[d.id] = d.device_class ? d.device_class.name.to_s : '?' }

agg = {}
unpaired.each do |s, e|
  e[:terms] = 0
  e[:inst] = {}
  e[:cls] = Hash.new(0)
  e[:tids] = Hash.new(0)
  agg[s] = e
end
pairs.each do |a, b|
  next unless a && b.nil?
  s = sig_hash(a)
  a.each_terminal do |t|
    e = agg[s]
    next unless e
    e[:terms] += 1
    e[:inst][inst[t.device.id] || '(unknown)'] = true
    e[:cls][classes[t.device.id]] += 1
    e[:tids][t.terminal_id.to_s] += 1
  end
end

# Pass D -- how many of the 752 non-Match device pairs have a terminal on each unpaired net.
members = Hash.new(0)
x.each_device_pair(cp) do |p|
  next unless p.first && p.second
  next if sname(p.status) == 'Match'
  hit = {}
  (dev_terms[p.first.id] || []).each do |tid|
    s = term_sig[[p.first.id, tid]]
    hit[s] = true if s && unpaired.key?(s)
  end
  hit.each_key { |s| members[s] += 1 }
end

File.open(OUT, 'w') do |fh|
  fh.puts "seq\tname\tterminals\tpairs\tinstances\tdevices\tterminal_ids"
  agg.each_with_index do |(s, e), i|
    fh.puts [i, e[:name], e[:terms], members[s] || 0, e[:inst].keys.sort.join(','),
             e[:cls].sort.map { |k, v| "#{k}=#{v}" }.join(' '),
             e[:tids].sort.map { |k, v| "#{k}=#{v}" }.join(' ')].join("\t")
  end
end
puts "nets written: #{agg.size}"
agg.sort_by { |s, _e| -(members[s] || 0) }.first(10).each do |s, e|
  puts format('  %-14s terms=%-4d pairs=%-3d inst=%s', e[:name][0, 14], e[:terms], members[s] || 0,
              e[:inst].keys.first(5).join(','))
end
puts "total pair memberships #{members.values.sum}"
puts "WROTE #{OUT}"
puts format('DONE %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
