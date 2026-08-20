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
