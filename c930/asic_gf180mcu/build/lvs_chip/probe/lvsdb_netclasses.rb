# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_netclasses.rb -- classify the nets in an lvsdb by what actually terminates them.
#
# The anchored die compares 424,912 layout nets with 370,842 schematic nets, a surplus of 54,070.
# A net count alone cannot say whether that is extra connectivity (a real defect) or extraction
# bookkeeping (wells, isolated shapes, labels on unused metal, nets cut at tile borders). This
# partitions each side's nets by `Net#terminal_count` -- the number of device/subcircuit terminals
# attached, not circuit pins -- and by naming, so the surplus can be attributed bucket by bucket.
#
#   klayout -b -r lvsdb_netclasses.rb -rd file=<report.lvsdb> [-rd examples=N]
#
# Read-only.
EXAMPLES = ($examples || 8).to_i
T0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read($file)
puts "READ #{'%.1f' % (Time.now - T0)} s"
x = lvs.xref
abort("NO-XREF") unless x

def bucket(tc)
  tc > 5 ? '5+' : tc.to_s
end

def short(s, n = 56)
  s = s.to_s
  s.length > n ? "#{s[0, n]}…" : s
end

def side(x, label, nl)
  return unless nl
  cc = nil
  nl.each_circuit { |c| cc = c }
  puts "== #{label}: #{cc.name}"

  hist = Hash.new(0)          # terminal-count bucket -> nets
  named = Hash.new(0)         # bucket -> named nets
  withpin = Hash.new(0)       # bucket -> nets carrying >=1 pin
  samples = Hash.new { |h, k| h[k] = [] }   # bucket -> sample names
  terms = 0
  pins_total = 0
  nets = 0
  by_name = Hash.new(0)       # net name -> how many distinct nets carry it
  cc.each_net do |n|
    nets += 1
    tc = n.terminal_count
    b = bucket(tc)
    hist[b] += 1
    terms += tc
    pins_total += n.pin_count
    withpin[b] += 1 if n.pin_count > 0
    nm = n.name
    if nm && !nm.empty?
      named[b] += 1
      samples[b] << nm if samples[b].size < EXAMPLES
      by_name[nm] += 1
    end
  end
  order = %w[0 1 2 3 4 5 5+]
  puts "nets=#{nets} terminals=#{terms} pins=#{pins_total} named=#{named.values.sum}"
  puts 'bucket  nets    unnamed  withpin  sample-names'
  order.each do |b|
    next if hist[b].zero?
    puts format('%-6s %-7d %-8d %-8d %s', b, hist[b], hist[b] - named[b], withpin[b],
                samples[b].first(4).map { |s| short(s) }.join(' | '))
  end

  # Names carried by more than one net: a netlist merges geometry into one net per node, so a name
  # on N nets means N fragments that the extractor did not join. Supply names are the big one.
  dup = by_name.select { |_, c| c > 1 }
  puts "distinct-names=#{by_name.size} names-on->1-net=#{dup.size} nets-in-those=#{dup.values.sum}"
  dup.sort_by { |_, c| -c }.first(8).each do |nm, c|
    puts "  DUP #{short(nm, 60)} nets=#{c}"
  end

  # The terminal count of each fragment says what the fragment is: a whole row's worth of bodies,
  # a cell's worth, or a stray labelled shape with nothing on it.
  pername = ($pername || '').to_s.split(',')
  unless pername.empty?
    pername.each do |nm|
      v = []
      cc.each_net { |n| v << n.terminal_count if n.name == nm }
      next if v.empty?
      v.sort!
      q = lambda { |p| v[((v.size - 1) * p).round] }
      puts format('  NAME %-8s nets=%-6d terminals min=%d p25=%d med=%d p75=%d max=%d sum=%d',
                  nm, v.size, v[0], q.call(0.25), q.call(0.5), q.call(0.75), v[-1], v.sum)
      puts format('       buckets: %s', %w[0 1 2 3 4 5 5+].map { |b| "#{b}=#{v.count { |t| bucket(t) == b }}" }.join(' '))
    end
  end

  zero = hist['0']
  puts "zero-terminal nets=#{zero} (all #{zero - named['0']} unnamed; with a pin: #{withpin['0']})"
  puts format('ELAPSED %.1f s', Time.now - T0)
  [hist, named]
end

a = side(x, 'layout', x.netlist_a)
b = side(x, 'schematic', x.netlist_b)
if a && b
  puts '== surplus by terminal count (layout - schematic)'
  (%w[0 1 2 3 4 5 5+] | a[0].keys | b[0].keys).uniq.sort_by { |k| k == '5+' ? 99 : k.to_i }.each do |k|
    d = a[0][k] - b[0][k]
    dn = a[1][k] - b[1][k]
    puts format('%-6s %+8d nets  (%+8d named)', k, d, dn) unless d.zero? && dn.zero?
  end
  puts format('TOTAL  %+8d nets', a[0].values.sum - b[0].values.sum)
end
$stdout.flush
# KLayout 0.29.4 segfaults in the destructor chain of a 691 MB lvsdb at interpreter shutdown.
exit!(0)
