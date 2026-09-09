## ---------------------------------------------------------------------------
## Minimal XDC for synthesis + implementation on xc7a200tfbg484-1
## No pin assignments — just clock definition for Fmax measurement.
## The actual board (Nexys Video) has a 100 MHz oscillator on different pins.
## ---------------------------------------------------------------------------

## 100 MHz clock (virtual — no pin assignment, for timing analysis only)
create_clock -name sys_clk -period 10.00 [get_ports { i_clk }]

## ---- Core clock: 100 MHz / CLK_DIV=2 -> 50 MHz ----
## Without this, every path inside the SoC is unconstrained (the Sep 5 run
## analyzed only 2 endpoints — the divider FF — and reported a vacuous
## "all constraints met").  Vivado flattens c930_soc_top, so the divider FF
## appears as g_clkgen.clk_div_reg (DONT_TOUCH keeps it from being renamed
## away).  If synthesis renames it anyway, this line warns and timing
## falls back to sys_clk-only coverage rather than failing the run.
create_generated_clock -name core_clk \
    -source [get_ports {i_clk}] \
    -divide_by 2 \
    [get_pins g_clkgen.clk_div_reg/Q]

## False paths on reset
set_false_path -from [get_ports { i_rst_n }]

## TB preload ports are tie-offs on the board, never real synchronous paths
set_false_path -from [get_ports { i_tb_wr_* }]
