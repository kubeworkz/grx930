# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_net_hist.rb -- full terminal-count histogram per side, supply nets optionally excluded.
#
# lvsdb_netclasses.rb shows the 54,070-net surplus is 13,436 zero-terminal + 1,205 one-terminal +
# 28,333 VDD/VSS fragments + ~12,241 others. The 12,241 is the part that still needs a shape: if the
# two sides hold the same terminals and differ only in how finely they are partitioned, the layout
# histogram should be the schematic's shifted towards fewer terminals per net, with equal totals.
#
#   klayout -b -r lvsdb_net_hist.rb -rd file=<report.lvsdb> [-rd nosupply=true]
NOSUPPLY = ($nosupply || '').to_s == 'true'
SUPPLY = %w[VDD VSS]
T0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read($file)
x = lvs.xref
abort('NO-XREF') unless x

def hist(x, nl)
  cc = nil
  nl.each_circuit { |c| cc = c }
  h = Hash.new(0)
  sums = Hash.new(0)
  terms = 0
  skipped = 0
  top = []
  cc.each_net do |n|
    if NOSUPPLY && SUPPLY.include?(n.name)
      skipped += 1
      next
    end
    t = n.terminal_count
    h[t > 10 ? 11 : t] += 1
    sums[t > 10 ? 11 : t] += t
    terms += t
    top << [t, n.name.to_s]
  end
  top.sort_by! { |t, _| -t }
  [h, terms, skipped, sums, top.first(6)]
end

a = hist(x, x.netlist_a)
b = hist(x, x.netlist_b)
puts format('supply nets excluded: %s', NOSUPPLY)
puts format('%-4s %10s %10s %8s %12s %12s', 'term', 'layout', 'schematic', 'diff', 'terms(L)', 'terms(S)')
(0..11).each do |k|
  label = k == 11 ? '11+' : k.to_s
  puts format('%-4s %10d %10d %+8d %12d %12d', label, a[0][k], b[0][k], a[0][k] - b[0][k], a[3][k], b[3][k])
end
puts format('%-4s %10d %10d %+8d', 'nets', a[0].values.sum, b[0].values.sum, a[0].values.sum - b[0].values.sum)
puts format('%-4s %10d %10d %+8d', 'terms', a[1], b[1], a[1] - b[1])
puts format('skipped supply nets: layout=%d schematic=%d', a[2], b[2])
puts 'largest nets in the layout:    ' + a[4].map { |t, nm| "#{t}d#{nm.empty? ? '' : "(#{nm[0, 24]})"}" }.join(' ')
puts 'largest nets in the schematic: ' + b[4].map { |t, nm| "#{t}d#{nm.empty? ? '' : "(#{nm[0, 24]})"}" }.join(' ')
puts format('ELAPSED %.1f s', Time.now - T0)
$stdout.flush
exit!(0)
