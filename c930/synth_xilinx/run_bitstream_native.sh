#!/bin/bash
# -----------------------------------------------------------------------------
# run_bitstream_native.sh  --  Generate the Arty A7-35T .bit from the WSL
# native-filesystem work copy (see run_impl_native.sh for why native FS).
#
# Launch detached so it survives terminal exit:
#   powershell -NoProfile -Command "Start-Process -WindowStyle Hidden -FilePath wsl.exe -ArgumentList '-e','bash','/mnt/c/<repo>/c930/synth_xilinx/run_bitstream_native.sh'"
#
# Log: /tmp/vivado_bit.log ; bitstream: ~/vivado_work/c930/build/vivado/
#   c930_artix7.runs/impl_1/c930_soc_top.bit
# -----------------------------------------------------------------------------

source /mnt/c/Users/kubew/Vivaldo/2026.1/Vivado/settings64.sh >/dev/null 2>&1
export XILINXD_LICENSE_FILE="$HOME/.Xilinx/Xilinx.lic"

cd "$HOME/vivado_work/c930/synth_xilinx" || exit 1
exec make bitstream > /tmp/vivado_bit.log 2>&1
