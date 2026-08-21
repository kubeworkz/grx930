#!/bin/bash
# -----------------------------------------------------------------------------
# run_bitstream_direct.sh  --  Run ONLY write_bitstream (single Vivado pass).
#
# Alternative to `make bitstream` when the routed design already exists:
# avoids the two-pass Makefile (impl reports + bitstream), which is fragile
# on memory-constrained WSL hosts.
#
# Launch detached:
#   powershell -NoProfile -Command "Start-Process -WindowStyle Hidden -FilePath wsl.exe -ArgumentList '-e','bash','/mnt/c/<repo>/c930/synth_xilinx/run_bitstream_direct.sh'"
#
# Log: /tmp/vivado_bit.log ; bitstream: ~/vivado_work/c930/build/vivado/
#   c930_artix7.runs/impl_1/c930_soc_top.bit
# -----------------------------------------------------------------------------

source /mnt/c/Users/kubew/Vivaldo/2026.1/Vivado/settings64.sh >/dev/null 2>&1
export XILINXD_LICENSE_FILE="$HOME/.Xilinx/Xilinx.lic"

cd "$HOME/vivado_work/c930/synth_xilinx" || exit 1
exec vivado -mode batch -source write_bitstream_only.tcl -log ../build/vivado/bitstream.log -journal ../build/vivado/bitstream.jou > /tmp/vivado_bit.log 2>&1
