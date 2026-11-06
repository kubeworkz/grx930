# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# net_api.rb -- what identity does a net actually have in this build?
#
# `well_net_trace.rb` keyed nets by `object_id` and reported a net named VSS with 545 terminals
# and no schematic partner, which contradicts the xref's 50 a-only nets. Ruby wrappers are not
# guaranteed to be one object per net, so this asks the build directly: does `Net` define
# `hash`/`eql?` (usable as a Hash key), is there an index, and can a circuit look a net up?
#
#   klayout -b -r net_api.rb
puts "VERSION #{RBA.const_defined?(:Version) ? RBA::Version : 'unknown'}"
if RBA.const_defined?(:Netlist) && RBA::Netlist.const_defined?(:Net)
  k = RBA::Netlist::Net
  own = (k.instance_methods - Object.instance_methods).map(&:to_s).sort
  puts "Net own methods: #{own.inspect}"
  puts "Net has hash: #{k.instance_methods.map(&:to_s).include?('hash')}"
  puts "Net has eql?: #{k.instance_methods.map(&:to_s).include?('eql?')}"
  puts "Net has ==:   #{k.instance_methods.map(&:to_s).include?('==')}"
end
if RBA.const_defined?(:Netlist) && RBA::Netlist.const_defined?(:Circuit)
  k = RBA::Netlist::Circuit
  own = (k.instance_methods - Object.instance_methods).map(&:to_s).sort
  puts "Circuit own methods: #{own.inspect}"
end
if RBA.const_defined?(:NetlistCrossReference)
  k = RBA::NetlistCrossReference
  puts "XRef net-ish methods: #{k.instance_methods.map(&:to_s).grep(/net/).sort.inspect}"
end
$stdout.flush
exit!(0)
