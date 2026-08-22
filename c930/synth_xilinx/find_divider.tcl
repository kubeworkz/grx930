# find_divider.tcl -- Discover the actual divider FF and core clock net in the synth checkpoint
open_checkpoint build/vivado/c930_artix7.runs/synth_1/c930_soc_top.dcp -quiet

puts "=== CELLS ==="
catch {foreach r [get_cells -hier -filter {NAME =~ *clk_cnt*}] { puts "CELL: $r" }}
catch {foreach r [get_cells -hier -filter {NAME =~ *clk_div*}] { puts "CELL: $r" }}

puts "=== CORE_CLK NETS ==="
catch {foreach n [get_nets -hier -filter {NAME =~ *core_clk*}] { puts "NET: $n" }}

puts "=== BUFGS ==="
catch {foreach b [get_cells -hier -filter {REF_NAME =~ BUFG}] { puts "BUFG: $b" }}

puts "=== ALL REGS WITH clk IN NAME ==="
catch {foreach r [get_cells -hier -filter {PRIMITIVE_TYPE =~ FLOP.LATCH} -of_objects [get_nets -hier -filter {NAME =~ *clk*}]] { puts "REG: $r" }}

close_design
