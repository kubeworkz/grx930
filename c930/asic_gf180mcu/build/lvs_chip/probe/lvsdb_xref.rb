# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_xref.rb -- read a KLayout lvsdb and report what the comparison actually decided.
#
# The deck ends with `ERROR : Netlists don't match`, which says nothing about *what* failed. The
# cross-reference stored in the lvsdb pairs every circuit, net, device, subcircuit and pin and keeps
# a status per pair: Match, MatchWithWarning (an ambiguous choice was made), Mismatch (a candidate
# exists but identity could not be confirmed), NoMatch (no candidate), Skipped, None. That partition
# is what separates a real defect (a device whose class or parameters differ, a cell that does not
# match) from a bound-induced one (top-level nets left unpaired or ambiguous).
#
#   klayout -b -r lvsdb_xref.rb -rd file=<report.lvsdb> [-rd examples=N]
#
# Read-only: it loads the database and walks the pairs.
EXAMPLES = ($examples || 12).to_i
t0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read($file)
puts "READ #{'%.1f' % (Time.now - t0)} s"
x = lvs.xref
abort("NO-XREF") unless x
puts "CIRCUITS #{x.circuit_count}"

# What each netlist contains, side by side: if the two sides carry the same counts and the pairs are
# still single-sided, the failure is pairing, not missing objects.
[[:a, x.netlist_a], [:b, x.netlist_b]].each do |label, nl|
  next unless nl
  begin
    counts = lambda do |cc|
      n = d = p = s = 0
      cc.each_net { n += 1 }
      cc.each_device { d += 1 }
      cc.each_pin { p += 1 }
      cc.each_subcircuit { s += 1 }
      [n, d, p, s]
    end
    circs = []
    nl.each_circuit { |cc| circs << cc }
    st = circs.map { |cc| [cc.name, *counts.call(cc)] }
    top = st.max_by { |r| r[2] }
    puts "NL #{label}: circuits=#{circs.size} top=#{top[0]} nets=#{top[1]} devices=#{top[2]} pins=#{top[3]} subcircuits=#{top[4]}"
    puts "NL #{label} circuits: " + st.first(40).map { |r| "#{r[0]}(#{r[2]}d/#{r[1]}n/#{r[4]}s)" }.join(", ")
    tc = circs.find { |cc| cc.name == top[0] }
    if tc
      h = Hash.new(0)
      tc.each_device { |d| h[(d.respond_to?(:device_class) && d.device_class) ? d.device_class.name : '?'] += 1 }
      puts "NL #{label} device classes: " + h.sort_by { |k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(" ")
    end
  rescue StandardError => e
    puts "NL #{label}: unreadable (#{e.class}: #{e.message})"
  end
end

# A net with 0 or 1 terminal is a dangling/one-ended node. The layout side carried 54,070 more nets
# than the CDL after the anchor fix; this histogram says whether the excess is exactly that shape.
puts "== net terminal counts"
[[:a, x.netlist_a], [:b, x.netlist_b]].each do |label, nl|
  next unless nl
  h = Hash.new(0)
  total = 0
  nl.each_circuit do |cc|
    cc.each_net do |n|
      total += 1
      # `pin_count` is the circuit-pin count, not device terminals; count the terminal refs instead.
      k = 0
      n.each_pin { |_ref| k += 1 }
      h[k > 6 ? '7+' : k.to_s] += 1
    end
  end
  puts "NL #{label}: #{total} nets, by terminals " + h.sort_by { |k, _| k == '7+' ? 99 : k.to_i }.map { |k, v| "#{k}=#{v}" }.join(" ")
end

X = RBA::NetlistCrossReference
def sname(s)
  return "Match" if s == X::Match
  return "MatchWithWarning" if s == X::MatchWithWarning
  return "Mismatch" if s == X::Mismatch
  return "NoMatch" if s == X::NoMatch
  return "Skipped" if s == X::Skipped
  return "None" if s == X::None
  s.to_s
end

def nname(o)
  return "(nil)" if o.nil?
  return o.expanded_name if o.respond_to?(:expanded_name)
  return o.name if o.respond_to?(:name)
  o.to_s
end

rows = []
x.each_circuit_pair do |cp|
  c = Hash.new(0)
  c[:net_both] = c[:net_a_only] = c[:net_b_only] = 0
  c[:dev_both] = c[:dev_a_only] = c[:dev_b_only] = 0
  x.each_net_pair(cp) do |p|
    c[:net] += 1; c["net_#{sname(p.status)}"] += 1
    c[p.first && p.second ? :net_both : (p.first ? :net_a_only : :net_b_only)] += 1
  end
  x.each_device_pair(cp) do |p|
    c[:dev] += 1; c["dev_#{sname(p.status)}"] += 1
    c[p.first && p.second ? :dev_both : (p.first ? :dev_a_only : :dev_b_only)] += 1
  end
  x.each_subcircuit_pair(cp){ |p| c[:sub] += 1; c["sub_#{sname(p.status)}"] += 1 }
  x.each_pin_pair(cp)       { |p| c[:pin] += 1; c["pin_#{sname(p.status)}"] += 1 }
  rows << [nname(cp.first || cp.second), sname(cp.status), c]
end
rows.sort_by! { |r| -r[2].values_at(:net, :dev, :sub, :pin).sum }

puts "== circuits by size (name [status] nets/devs/subs/pins, then non-Match counts)"
rows.first(50).each do |name, st, c|
  bad = c.select { |k, _| k.is_a?(String) && !k.end_with?("_Match") }.map { |k, v| "#{k}=#{v}" }.join(" ")
  puts "CIRC #{name} [#{st}] nets=#{c[:net]} devs=#{c[:dev]} subs=#{c[:sub]} pins=#{c[:pin]}"
  puts "      paired nets=#{c[:net_both]} (a-only #{c[:net_a_only]}, b-only #{c[:net_b_only]}), " \
       "devices=#{c[:dev_both]} (a-only #{c[:dev_a_only]}, b-only #{c[:dev_b_only]})"
  puts "      #{bad}" unless bad.empty?
end

tot = Hash.new(0)
rows.each { |_, _, c| c.each { |k, v| tot[k] += v if k.is_a?(String) } }
puts "TOTAL " + tot.sort.map { |k, v| "#{k}=#{v}" }.join(" ")

# Examples from the largest circuit (the die's top level): the nets are the interesting ones, because
# a bound that aborts ambiguity resolution shows up as NoMatch/Mismatch/MatchWithWarning nets while
# devices and cells still pair.
top_name = rows.first && rows.first[0]

# A pair with both sides is the only place a *real* mismatch can live: the cap leaves the rest
# single-sided. Count the both-sided non-Match pairs and, for devices, which classes met.
both_net = both_dev = 0
cls = Hash.new(0)
dev_examples = []
x.each_circuit_pair do |cp|
  next unless (cp.first || cp.second).respond_to?(:name) && (cp.first || cp.second).name == top_name
  x.each_net_pair(cp) { |p| both_net += 1 if p.first && p.second && sname(p.status) != "Match" }
  x.each_device_pair(cp) do |p|
    next unless p.first && p.second && sname(p.status) != "Match"
    both_dev += 1
    ca = (p.first.respond_to?(:device_class) && p.first.device_class) ? p.first.device_class.name : "?"
    cb = (p.second.respond_to?(:device_class) && p.second.device_class) ? p.second.device_class.name : "?"
    cls["#{ca} -> #{cb}"] += 1
    dev_examples << [sname(p.status), nname(p.first), ca, nname(p.second), cb] if dev_examples.size < EXAMPLES
  end
  break
end
puts "== both-sided non-Match in #{top_name}: nets=#{both_net} devices=#{both_dev}"
puts "device class pairs: " + cls.sort_by { |_k, v| -v }.first(8).map { |k, v| "#{k}=#{v}" }.join(" ")
dev_examples.each { |s, a, ca, b, cb| puts "DEV  #{s}: layout=#{a} [#{ca}] schematic=#{b} [#{cb}]" }

puts "== examples from #{top_name}"
x.each_circuit_pair do |cp|
  next unless (cp.first || cp.second).respond_to?(:name) && (cp.first || cp.second).name == top_name
  shown = Hash.new(0)
  x.each_net_pair(cp) do |p|
    s = sname(p.status)
    next if s == "Match" || shown["net_#{s}"] >= EXAMPLES
    shown["net_#{s}"] += 1
    puts "NET  #{s}: layout=#{nname(p.first)} schematic=#{nname(p.second)}"
  end
  x.each_device_pair(cp) do |p|
    s = sname(p.status)
    next if s == "Match" || shown["dev_#{s}"] >= EXAMPLES
    shown["dev_#{s}"] += 1
    ca = p.first.respond_to?(:device_class) ? p.first.device_class.name : "?"
    cb = p.second.respond_to?(:device_class) ? p.second.device_class.name : "?"
    puts "DEV  #{s}: layout=#{nname(p.first)} [#{ca}] schematic=#{nname(p.second)} [#{cb}]"
  end
  x.each_subcircuit_pair(cp) do |p|
    s = sname(p.status)
    next if s == "Match" || shown["sub_#{s}"] >= EXAMPLES
    shown["sub_#{s}"] += 1
    puts "SUB  #{s}: layout=#{nname(p.first)} schematic=#{nname(p.second)}"
  end
  x.each_pin_pair(cp) do |p|
    s = sname(p.status)
    next if s == "Match" || shown["pin_#{s}"] >= EXAMPLES
    shown["pin_#{s}"] += 1
    puts "PIN  #{s}: layout=#{nname(p.first)} schematic=#{nname(p.second)}"
  end
  break
end
puts "DONE #{'%.1f' % (Time.now - t0)} s"
# KLayout 0.29.4 segfaults in the destructor chain of a 561 MB lvsdb at interpreter shutdown
# (LayoutVsSchematicD1Ev -> NetlistD1Ev), after all output is written. Skip teardown entirely.
$stdout.flush
exit!(0)
