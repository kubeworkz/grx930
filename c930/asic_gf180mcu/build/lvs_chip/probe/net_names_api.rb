# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# net_names_api.rb -- is `consider_net_names` reachable on this build, and what is its default?
#
# The September labelled die carried 148,715 instance-qualified net names into the extracted
# netlist and the comparison did not move a single pair (370,046 nets / 690,114 devices / 242
# pairs, identical to the unlabelled run). A name the comparer never reads looks exactly like a
# name that does not help, so the deck's `compare` has to be told to use names -- and whether
# that switch exists at all is a property of the installed KLayout, not of the deck.
#
#   klayout -b -r net_names_api.rb
puts "VERSION #{RBA.const_defined?(:Version) ? RBA::Version : 'unknown'}"

if RBA.const_defined?(:NetlistComparer)
  k = RBA::NetlistComparer
  puts "NetlistComparer name-ish methods: #{k.instance_methods.map(&:to_s).grep(/name|consider/).sort.inspect}"
  c = k.new
  if c.respond_to?(:consider_net_names)
    puts "default consider_net_names=#{c.consider_net_names.inspect}"
    if c.respond_to?(:consider_net_names=)
      c.consider_net_names = true
      puts "after consider_net_names=true: #{c.consider_net_names.inspect}"
    else
      puts "consider_net_names is read-only here"
    end
  else
    puts "NetlistComparer has NO consider_net_names"
  end
else
  puts "no RBA::NetlistComparer"
end

# The deck calls the DSL form; outside a deck the method is not defined, which is expected. The
# real check is the `respond_to?` the deck itself raises on.
begin
  puts "DSL consider_net_names arity=#{method(:consider_net_names).arity}"
rescue NameError
  puts "DSL consider_net_names: not defined outside a deck (expected)"
end
$stdout.flush
exit!(0)
