# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvs_api_shapes.rb -- what shape/net API does this engine actually expose?
#
# `lvs.shapes_of_net(net, region)` answers "Non-hierarchical layers cannot be used in netlist
# extraction" for every layer index in a flat-mode lvsdb, so the next step is not another guess at
# the arguments: it is the method list of the installed build.
#
#   klayout -b -r lvs_api_shapes.rb
$stdout.sync = true
[['LayoutVsSchematic', RBA::LayoutVsSchematic],
 ['LayoutToNetlist', RBA::LayoutToNetlist]].each do |name, klass|
  puts "== #{name} (#{RBA.const_defined?(:Version) ? 'RBA' : 'RBA'})"
  ms = (klass.instance_methods(false) | klass.public_instance_methods(false)).map(&:to_s).sort.uniq
  puts '  ' + ms.grep(/shape|layer|net|shape_of|region/i).join(' ')
end
puts "== version #{RBA::Application.instance.version rescue '?'}"
exit!(0)
