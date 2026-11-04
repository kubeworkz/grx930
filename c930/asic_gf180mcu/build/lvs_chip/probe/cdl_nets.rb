# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# cdl_nets.rb -- the schematic side of the die census, read the way the deck reads it.
#
# The die census (build/lvs_chip_census.sh) reports the *layout* net partition from an lvsdb.
# After changing how tools/lvs_chip/mk_chip_cdl.py binds the bulk pins there is no lvsdb for the
# new CDL yet, and extracting the die to get one costs ~25 min. This reads the CDL directly with
# the same SPICE reader the deck uses, flattens it, and prints the same quantities: net count,
# zero-terminal nets, and terminal counts for VDD/VSS -- so the check is "does the schematic
# partition now look like the layout's", not "did the text of the file change".
#
#   klayout -b -r cdl_nets.rb -rd file=<netlist.cdl> [-rd top=<net>] [-rd supply=VDD,VSS]
#
# Exit status is always 0; a refusal prints and calls exit!(2).
t0 = Time.now
nl = RBA::Netlist.new
begin
  # The parser is a delegate handed to the netlist, not a reader that owns the netlist.
  nl.read($file.to_s, RBA::NetlistSpiceReader.new)
rescue StandardError => e
  puts "REFUSED  cannot read #{$file}: #{e.class}: #{e.message}"
  $stdout.flush
  exit!(2)
end
flat = nl.flatten
cc = nil
flat.each_circuit { |c| cc = c }
unless cc
  puts 'REFUSED  no circuit in the netlist'
  $stdout.flush
  exit!(2)
end

ndev = 0
cls = Hash.new(0)
cc.each_device { |d| ndev += 1; cls[d.device_class.name] += 1 }
npin = 0
cc.each_pin { |_| npin += 1 }
puts format('CDL %s read in %.1f s', File.basename($file.to_s), Time.now - t0)
puts "CDL top=#{cc.name} devices=#{ndev} pins=#{npin}"
puts 'CDL classes ' + cls.sort_by { |_, v| -v }.map { |k, v| "#{k}=#{v}" }.join(' ')

# Supply names are the ones the deck will look for when it pairs the body terminals.
want = ($supply || 'VDD,VSS').split(',')
stats = Hash.new { |h, k| h[k] = [0, 0] }
zero = 0
total_terms = 0
nnet = 0
big = []
cc.each_net do |n|
  nnet += 1
  tc = n.terminal_count
  total_terms += tc
  zero += 1 if tc.zero?
  nm = n.name.to_s
  big << [tc, nm.empty? ? '(unnamed)' : nm]
  want.each do |w|
    next unless !nm.empty? && (nm == w || nm.start_with?("#{w}."))
    stats[w][0] += 1
    stats[w][1] += tc
  end
end
puts format('CDL nets=%d zero-terminal=%d terminals=%d', nnet, zero, total_terms)
want.each { |w| puts format('CDL supply %s nets=%d terminals=%d', w, stats[w][0], stats[w][1]) }
big.sort_by! { |tc, _| -tc }
big.first(6).each do |tc, nm|
  nm = nm.length > 48 ? "#{nm[0, 48]}…" : nm
  puts format('CDL big-net %10d  %s', tc, nm)
end
$stdout.flush
exit!(0)
