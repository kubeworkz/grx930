#!/bin/bash
export XILINX_VIVADO=/mnt/c/Users/kubew/Vivaldo/2026.1/Vivado
source /mnt/c/Users/kubew/Vivaldo/2026.1/Vivado/settings64.sh
cd /mnt/c/Users/kubew/grx930/c930/build/vivado
nohup vivado -mode batch -source /mnt/c/Users/kubew/grx930/c930/synth_xilinx/run_impl_only.tcl \
    -log /mnt/c/Users/kubew/grx930/c930/build/vivado/run6.log \
    -journal /mnt/c/Users/kubew/grx930/c930/build/vivado/run6.jou \
    > /tmp/vivado_impl6.log 2>&1 &
echo "Vivado PID: $!"
