## ---------------------------------------------------------------------------
## Minimal XDC for synthesis + implementation on xc7a200tfbg484-1
## No pin assignments — just clock definition for Fmax measurement.
## The actual board (Nexys Video) has a 100 MHz oscillator on different pins.
## ---------------------------------------------------------------------------

## 100 MHz clock (virtual — no pin assignment, for timing analysis only)
create_clock -name sys_clk -period 10.00 [get_ports { i_clk }]

## False paths on reset
set_false_path -from [get_ports { i_rst_n }]
