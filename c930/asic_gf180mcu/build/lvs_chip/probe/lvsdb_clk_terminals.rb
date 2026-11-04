# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_clk_terminals.rb -- why a net pair with identical terminal counts is still `Mismatch`.
#
# The stitched exact-RECT die pairs `CLK,i_clk` (28,988 terminals) with `I_CLK` (28,988) and still
# reports `Mismatch`. A net is only confirmed when its terminals correspond one-to-one, and a
# terminal corresponds only if its *device* paired, so the answer is a count: how many of the
# clock's terminals sit on devices whose pair is not `Match`, and which ones.
#
#   klayout -b -r lvsdb_clk_terminals.rb -rd file=<report.lvsdb> [-rd want=i_clk] [-rd examples=8]
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

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-CIRCUIT-PAIR') unless cp
puts "CIRCUIT #{nname(cp.first || cp.second)} [#{sname(cp.status)}]"

# Device status, from the same partition the net walk uses. Keyed by `device.id`, not by the Ruby
# object: `net.each_terminal.device` hands back a fresh wrapper each call, so a Hash on the object
# finds nothing (measured: every terminal of a net that does pair came back "unpaired"). The two
# sides keep separate maps -- their ids collide, and one map for both silently mixed the statuses
# (measured: 691,010 keys out of 1,382,020 inserts, and a Mismatch count that matched neither side).
dev_a = {}
dev_b = {}
pairs = 0
shape = Hash.new(0)
x.each_device_pair(cp) do |p|
  pairs += 1
  st = sname(p.status)
  dev_a[p.first.id] = st if p.first
  dev_b[p.second.id] = st if p.second
  shape[p.first && p.second ? "both_#{st}" : (p.first ? 'layout_only' : 'schematic_only')] += 1
end
puts 'DEVICE PAIR SHAPE ' + shape.sort_by { |_k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(' ')
puts "DEVICE PAIRS #{pairs}, layout keys #{dev_a.size}, schematic keys #{dev_b.size}"
puts 'DEVICE STATUS layout    ' + dev_a.values.tally.sort_by { |_k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(' ')
puts 'DEVICE STATUS schematic ' + dev_b.values.tally.sort_by { |_k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(' ')

want_pair = nil
x.each_net_pair(cp) do |p|
  a = nname(p.first).downcase
  b = nname(p.second).downcase
  next unless a.include?(WANT) || b.include?(WANT)
  want_pair = p
  break
end
abort("NO-NET (#{WANT})") unless want_pair
puts "NET PAIR layout=#{nname(want_pair.first)} schematic=#{nname(want_pair.second)} " \
     "status=#{sname(want_pair.status)}"

[[nname(want_pair.first), want_pair.first, dev_a],
 [nname(want_pair.second), want_pair.second, dev_b]].each do |label, net, dev_status|
  next unless net
  h = Hash.new(0)
  cls = Hash.new(0)
  bad = []
  k = 0
  net.each_terminal do |t|
    k += 1
    d = t.device
    st = d ? (dev_status[d.id] || 'unpaired') : 'no-device'
    h[st] += 1
    next if st == 'Match'
    c = (d && d.respond_to?(:device_class) && d.device_class) ? d.device_class.name : '?'
    cls["#{st} #{c}"] += 1
    bad << [st, nname(d), c, t.terminal_id] if bad.size < EXAMPLE
  end
  puts "-- #{label}: #{k} terminals"
  puts "   by device status " + h.sort_by { |_k2, v| -v }.map { |k2, v| "#{k2}=#{v}" }.join(' ')
  puts "   classes " + cls.sort_by { |_k2, v| -v }.first(8).map { |k2, v| "#{k2}=#{v}" }.join(' ')
  bad.each do |st, dn, c, tid|
    puts format('   %-14s device=%-14s [%-12s] terminal %d', st, dn[0, 14], c, tid)
  end
end

puts format('DONE %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
