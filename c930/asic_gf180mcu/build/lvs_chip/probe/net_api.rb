# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# net_api.rb -- what the installed engine offers for walking net connectivity (no lvsdb load).
#
#   klayout -b -r net_api.rb
puts "KLAYOUT #{RBA::Application.instance.version}"
puts "NET:  #{RBA::Net.instance_methods.grep(/term|pin|name|cluster|supply|ground/i).sort.inspect}"
puts "DEV:  #{RBA::Device.instance_methods.grep(/term|net|name|class/i).sort.inspect}"
puts "PIN:  #{RBA::Pin.instance_methods.grep(/name|net|id/i).sort.inspect}"
puts "CIRC: #{RBA::Circuit.instance_methods.grep(/pin|net|device/i).sort.inspect}"
puts "NL:   #{RBA::Netlist.instance_methods.grep(/top|circuit|device|net/i).sort.inspect}"
$stdout.flush
exit!(0)
