#!/bin/bash
# -----------------------------------------------------------------------------
# run_impl_native.sh  --  Run Vivado impl from the WSL NATIVE filesystem copy.
#
# Why: the /mnt/c (drvfs) mount is slow AND wedges under Vivado I/O + memory
# pressure. The flow was copied to ~/vivado_work (WSL ext4) and is run from
# there; Vivado itself stays installed at /mnt/c/Users/kubew/Vivaldo.
#
# Launch detached so it survives terminal exit:
#   cmd //c "start /b wsl.exe -e bash /mnt/c/<repo>/c930/synth_xilinx/run_impl_native.sh"
#
# Log: /tmp/vivado_native.log (poll: wsl.exe -e bash -lc 'tail -20 /tmp/vivado_native.log')
# -----------------------------------------------------------------------------

source /mnt/c/Users/kubew/Vivaldo/2026.1/Vivado/settings64.sh >/dev/null 2>&1
export XILINXD_LICENSE_FILE="$HOME/.Xilinx/Xilinx.lic"

cd "$HOME/vivado_work/c930/synth_xilinx" || exit 1
exec make impl > /tmp/vivado_native.log 2>&1
