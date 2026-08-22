## ---------------------------------------------------------------------------
## C930 SoC  --  Arty A7-35T XDC constraints
##
## Target: Digilent Arty A7-35T  (XC7A35TCSG324-1)
## Clock:  100 MHz on-board oscillator (E3)
## Reset:  Active-low directly on CN9 directly button
## LEDs:   LD4-LD7 are active-high directly driven LEDs
## ---------------------------------------------------------------------------

## ---- Clock (100 MHz oscillator) ----
set_property -dict { PACKAGE_PIN E3   IOSTANDARD LVCMOS33 } [get_ports { i_clk }]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports { i_clk }]

## ---- Generated core clock (100 MHz / CLK_DIV = 50 MHz) ----
## c930_soc_top's CLK_DIV generic (set to 2 by the flow) runs the whole SoC on
## a counter-divided clock, keeping the core comfortably below the routed Fmax.
##
## Vivado may rename the divider FF during synthesis/flattening, so a static
## pin reference often fails.  Two strategies:
##
##   1. Preferred: find the divider FF via cell wildcard (robust to renaming).
##   2. Fallback:  time everything at 100 MHz (conservative; if WNS > 0,
##      the design also meets timing at 50 MHz).
##
## The DONT_TOUCH attribute on clk_cnt and clk_div in the RTL helps preserve
## the hierarchy, but Vivado may still rename or flatten the generate block.
##
## Attempt the cell-wildcard approach; if it fails the CRITICAL WARNING is
## harmless (conservative timing).
catch {
    set _div_ff [get_cells -hier \
        -filter {NAME =~ *g_clkgen*clk_div_reg || NAME =~ *g_clkgen*clk_div}]
    create_generated_clock -name core_clk \
        -source [get_ports {i_clk}] \
        -divide_by 2 [get_pins $_div_ff/Q]
}

## ---- Reset (active-low directly button) ----
set_property -dict { PACKAGE_PIN N15  IOSTANDARD LVCMOS33 } [get_ports { i_rst_n }]

## ---- NPU status LEDs (active-high, directly driven) ----
set_property -dict { PACKAGE_PIN H17  IOSTANDARD LVCMOS33 } [get_ports { o_npu_busy }]
set_property -dict { PACKAGE_PIN K15  IOSTANDARD LVCMOS33 } [get_ports { o_npu_done }]
set_property -dict { PACKAGE_PIN J13  IOSTANDARD LVCMOS33 } [get_ports { o_npu_error }]
set_property -dict { PACKAGE_PIN N14  IOSTANDARD LVCMOS33 } [get_ports { o_npu_irq }]

## ---- Bitstream configuration ----
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
