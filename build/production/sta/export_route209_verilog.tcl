read_db /work/build/lvs_chip/eco_drop_2x2/stage6/eco_routed_route209.odb
set block [ord::get_db_block]
puts "EXPORT_BLOCK [$block getName]"
write_verilog /work/build/production/sta/eco_routed_route209_export.v
puts "EXPORT_DONE"
exit
