# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# well_nets2.rb -- the layout nets with no schematic partner, asked of the xref directly.
#
# The first attempt keyed nets by Ruby `object_id` and reported a VSS with 545 terminals and no
# partner, which contradicts the xref's own 50 a-only nets: wrappers are not one object per net.
# `NetlistCrossReference#other_net_for(net)` answers the question without any identity at all --
# nil means the net has no partner, and the same call classifies each device terminal. The
# instance behind a terminal comes from `other_device_for(device)`, whose name is
# `<instance>.<device>` on the schematic side.
#
#   klayout -b -r well_nets2.rb -rd file=<report.lvsdb> -rd out=<tsv>
FILE = $file
OUT = $out
abort('usage: -rd file=<report.lvsdb> -rd out=<tsv>') unless FILE && OUT

t0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
puts format('READ %.1f s', Time.now - t0)
x = lvs.xref
abort('NO-XREF') unless x
abort('NO-other_net_for') unless x.respond_to?(:other_net_for)

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-PAIR') unless cp

def nname(o)
  return '(nil)' if o.nil?
  return o.expanded_name if o.respond_to?(:expanded_name)
  return o.name if o.respond_to?(:name)
  o.to_s
end

def dname(d)
  return '(nil)' if d.nil?
  return d.expanded_name if d.respond_to?(:expanded_name)
  return d.name if d.respond_to?(:name)
  d.to_s
end

unpaired = []
cp.first.each_net do |n|
  next unless x.other_net_for(n).nil?
  insts = {}
  cls = Hash.new(0)
  tids = Hash.new(0)
  terms = 0
  n.each_terminal do |t|
    d = t.device
    next unless d
    terms += 1
    tids[t.terminal_id.to_s] += 1
    cls[d.device_class ? d.device_class.name.to_s : '?'] += 1
    sd = x.respond_to?(:other_device_for) ? x.other_device_for(d) : nil
    insts[dname(sd).split('.', 2).first] = true if sd
  end
  unpaired << { name: nname(n), terms: terms, inst: insts.keys.sort,
                cls: cls.sort.map { |k, v| "#{k}=#{v}" }.join(' '),
                tids: tids.sort.map { |k, v| "#{k}=#{v}" }.join(' ') }
end

File.open(OUT, 'w') do |fh|
  fh.puts "seq\tname\tterminals\tpairs\tinstances\tdevices\tterminal_ids"
  unpaired.each_with_index do |a, i|
    fh.puts [i, a[:name], a[:terms], a[:terms], a[:inst].join(','), a[:cls], a[:tids]].join("\t")
  end
end
puts "UNPAIRED LAYOUT NETS: #{unpaired.size} (xref says a-only 50)"
unpaired.sort_by { |a| -a[:terms] }.first(12).each do |a|
  puts format('  %-16s terms=%-4d inst=%s', a[:name][0, 16], a[:terms], a[:inst].first(4).join(','))
end
puts "WROTE #{OUT}"
puts format('DONE %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
