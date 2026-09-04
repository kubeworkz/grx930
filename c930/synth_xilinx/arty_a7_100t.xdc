## ---------------------------------------------------------------------------
## C930 SoC  --  Arty A7-100T XDC constraints
##
## Target: Digilent Arty A7-100T  (XC7A200TCSG324-1 — 200T for 8x8 NPU)
## Clock:  100 MHz on-board oscillator (E3)
## Reset:  Active-high directly button (N15)
## LEDs:   LD0-LD7 are active-high directly driven LEDs
##
## Current SoC top-level ports: i_clk, i_rst_n, o_npu_busy/done/error/irq,
##   o_uart_txd, i_uart_rxd, i_tb_wr_en/addr/data (tied off in synth).
## Other board pins are documented below for future board-wrapper use.
## ---------------------------------------------------------------------------


## ============================================================================
## 1. ACTIVE DESIGN PORTS (SoC top-level I/O)
## ============================================================================

## ---- Clock (100 MHz oscillator on E3) ----
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
## Create a generated clock on the divider register output.
## Vivado flattens the c930_soc_top wrapper during synthesis, so the
## divider FF appears as g_clkgen.clk_div_reg (no top-level prefix).
## The post-implementation clock_utilization report confirms this path.
## CRITICAL: create_generated_clock needs a PIN (not a cell), so use
## get_pins with the flat name.  The /Q pin works because it is the
## clock input to the divider — Vivado infers the /Q output.
create_generated_clock -name core_clk \
    -source [get_ports {i_clk}] \
    -divide_by 2 \
    [get_pins g_clkgen.clk_div_reg/Q]

## ---- Reset (active-high directly button) ----
set_property -dict { PACKAGE_PIN N15  IOSTANDARD LVCMOS33 } [get_ports { i_rst_n }]

## ---- NPU status LEDs (active-high, directly driven) ----
set_property -dict { PACKAGE_PIN H17  IOSTANDARD LVCMOS33 } [get_ports { o_npu_busy }]
set_property -dict { PACKAGE_PIN K15  IOSTANDARD LVCMOS33 } [get_ports { o_npu_done }]
set_property -dict { PACKAGE_PIN J13  IOSTANDARD LVCMOS33 } [get_ports { o_npu_error }]
set_property -dict { PACKAGE_PIN N14  IOSTANDARD LVCMOS33 } [get_ports { o_npu_irq }]

## ---- UART (FTDI FT2232H channel B, directly connected) ----
set_property -dict { PACKAGE_PIN C4   IOSTANDARD LVCMOS33 } [get_ports { o_uart_txd }]
set_property -dict { PACKAGE_PIN D4   IOSTANDARD LVCMOS33 } [get_ports { i_uart_rxd }]

## ---- DDR preload port (tied off in synthesis) ----
set_property -dict { PACKAGE_PIN N17  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_en }]
set_property -dict { PACKAGE_PIN M18  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_addr[0] }]
set_property -dict { PACKAGE_PIN P18  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_addr[1] }]
set_property -dict { PACKAGE_PIN R18  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_addr[2] }]
set_property -dict { PACKAGE_PIN V17  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_addr[3] }]
set_property -dict { PACKAGE_PIN U17  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_addr[4] }]
set_property -dict { PACKAGE_PIN U16  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_addr[5] }]
set_property -dict { PACKAGE_PIN V16  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_addr[6] }]
set_property -dict { PACKAGE_PIN T15  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_addr[7] }]
set_property -dict { PACKAGE_PIN U14  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_addr[8] }]
set_property -dict { PACKAGE_PIN T16  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_addr[9] }]
set_property -dict { PACKAGE_PIN V15  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_addr[10] }]
set_property -dict { PACKAGE_PIN V14  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_addr[11] }]
set_property -dict { PACKAGE_PIN V12  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_data[0] }]
set_property -dict { PACKAGE_PIN V11  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_data[1] }]
set_property -dict { PACKAGE_PIN V10  IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_data[2] }]
set_property -dict { PACKAGE_PIN W8   IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_data[3] }]
set_property -dict { PACKAGE_PIN U8   IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_data[4] }]
set_property -dict { PACKAGE_PIN W7   IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_data[5] }]
set_property -dict { PACKAGE_PIN U5   IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_data[6] }]
set_property -dict { PACKAGE_PIN V5   IOSTANDARD LVCMOS33 } [get_ports { i_tb_wr_data[7] }]

## Mark TB preload as false path (testbench only, never used in real operation)
set_false_path -from [get_ports { i_tb_wr_* }]


## ============================================================================
## 2. BOARD PIN MAP (reference for future board wrapper)
##
## When a board-level wrapper is added (c930_soc_top_artix), constrain
## these ports using the PACKAGE_PIN values below.  All Arty A7-100T pins
## use LVCMOS33 (3.3V bank 35 or bank 14/34).
## ============================================================================

## --- Push buttons (active-high, active when pressed) ---
## D18  btn[0]    E18  btn[1]    G17  btn[2]    M17  btn[3]

## --- Slide switches ---
## J15  sw[0]     L16  sw[1]     M13  sw[2]     R15  sw[3]

## --- Remaining LEDs (LD0-LD3, active-high) ---
## H17  LED[0]    K15  LED[1]    J13  LED[2]    N14  LED[3]

## --- USB-UART (FTDI FT2232H channel B, directly connected) ---
## D4   uart_rxd  (from FTDI TXD — FPGA input)
## C4   uart_txd  (to FTDI RXD — FPGA output)

## --- QSPI Flash (W25Q128JV, shared with SPI-Flash boot) ---
## L13  qspi_cs       K18  qspi_sck      D18  qspi_dq[0]
## D19  qspi_dq[1]    G18  qspi_dq[2]    F18  qspi_dq[3]
## NOTE: Bitstream boots from this flash in SPIx4 mode. After boot the
## flash is deselected (CS high) unless the CPU explicitly accesses it.

## --- Micro SD Card (directly connected, SPI mode) ---
## E2   sd_cs     A1   sd_sck    B1   sd_mosi   C1   sd_miso   C2   sd_cd

## --- I2C Bus (shared with ADXL345 accelerometer/gyro on board) ---
## A14  i2c_scl   A16  i2c_sda
## External 4.7K pull-ups on the Arty board keep the bus idle-high.

## --- SPI (shared with ADXL345) ---
## F14  spi_miso  G14  spi_ss    D14  spi_mosi  F16  spi_sck

## --- Pmod JA (directly connected to FPGA) ---
## G13  ja[0]  B16  ja[1]  A15  ja[2]  A16  ja[3]
## A14  ja[4]  B15  ja[5]  A17  ja[6]  C15  ja[7]

## --- Pmod JB (directly connected to FPGA) ---
## D14  jb[0]  F16  jb[1]  G16  jb[2]  H14  jb[3]
## E16  jb[4]  F13  jb[5]  G13  jb[6]  H16  jb[7]

## --- Pmod JC (directly connected to FPGA) ---
## K1   jc[0]  F6   jc[1]  J2   jc[2]  G6   jc[3]
## E7   jc[4]  J3   jc[5]  J4   jc[6]  E6   jc[7]

## --- Pmod JD (directly connected to FPGA) ---
## H4   jd[0]  H1   jd[1]  G1   jd[2]  G3   jd[3]
## H2   jd[4]  G4   jd[5]  G2   jd[6]  F3   jd[7]

## --- Pmod JADC (directly connected to FPGA) ---
## B13  jadc[0]  F1   jadc[1]  B14  jadc[2]  D2   jadc[3]
## E2   jadc[4]  A14  jadc[5]  D1   jadc[6]  A16  jadc[7]

## --- ChipKit digital headers (directly connected to FPGA) ---
## V10  ck_io[0]   W8   ck_io[1]   U7   ck_io[2]   V7   ck_io[3]
## W7   ck_io[4]   U8   ck_io[5]   V8   ck_io[6]   V5   ck_io[7]
## U5   ck_io[8]   W6   ck_io[9]   W5   ck_io[10]  U3   ck_io[11]
## P3   ck_io[12]  P4   ck_io[13]  V5   ck_io[14]  W4   ck_io[15]

## --- ChipKit serial (directly connected to FPGA) ---
## W6   ck_sda     W5   ck_scl

## --- ChipKit analog headers (directly connected to FPGA) ---
## A5   ck_an[0]   B4   ck_an[1]   C5   ck_an[2]
## A3   ck_an[3]   B3   ck_an[4]   C4   ck_an[5]

## --- USB reset (directly connected to FPGA) ---
## C13  usb_rst


## ============================================================================
## 3. BITSTREAM CONFIGURATION
## ============================================================================

set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
