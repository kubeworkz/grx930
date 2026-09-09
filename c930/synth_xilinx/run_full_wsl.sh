#!/bin/bash
# -----------------------------------------------------------------------------
# run_full_wsl.sh  --  Fresh full Vivado flow for the CURRENT C930 SoC:
# project create (re-globbed RTL) + synthesis + implementation + bitstream.
#
# Launched from WSL through a detached Windows client so it survives the
# terminal session ending:
#   cmd //c "start /b wsl.exe -e bash /mnt/c/<repo>/c930/synth_xilinx/run_full_wsl.sh"
#
# Log: /tmp/vivado_full.log (inside WSL; poll with
#   wsl.exe -e bash -lc 'tail -20 /tmp/vivado_full.log')
# -----------------------------------------------------------------------------

source /mnt/c/Users/kubew/Vivaldo/2026.1/Vivado/settings64.sh >/dev/null 2>&1 || {
    echo "ERROR: Vivado settings64.sh not found" >> /tmp/vivado_full.log
    exit 1
}
export XILINXD_LICENSE_FILE="$HOME/.Xilinx/Xilinx.lic"

cd /mnt/c/Users/kubew/grx930/c930 || exit 1

echo "=== full flow started $(date) ===" >> /tmp/vivado_full.log
bash synth_xilinx/create_and_synth.sh >> /tmp/vivado_full.log 2>&1
rc=$?
echo "=== full flow finished $(date) rc=$rc ===" >> /tmp/vivado_full.log
exit $rc