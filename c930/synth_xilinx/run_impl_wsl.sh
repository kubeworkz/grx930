#!/bin/bash
# -----------------------------------------------------------------------------
# run_impl_wsl.sh  --  Run the Vivado impl flow from WSL, surviving terminal exit.
#
# WSL2 tears down the distro when the last wsl.exe client exits, killing any
# backgrounded jobs. Launch this script through a detached Windows process so a
# wsl.exe client stays attached for the whole run:
#
#   cmd //c "start /b wsl.exe -e bash /mnt/c/<repo>/c930/synth_xilinx/run_impl_wsl.sh"
#
# Log goes to /tmp/vivado_impl.log inside WSL (poll with:
#   wsl.exe -e bash -lc 'tail -20 /tmp/vivado_impl.log')
# -----------------------------------------------------------------------------

# Point at the installed Vivado (adjust the path to your install location).
if [ -f /mnt/c/Users/kubew/Vivaldo/2026.1/Vivado/settings64.sh ]; then
    source /mnt/c/Users/kubew/Vivaldo/2026.1/Vivado/settings64.sh >/dev/null 2>&1
else
    echo "ERROR: Vivado settings64.sh not found" >> /tmp/vivado_impl.log
    exit 1
fi

# --- License discovery -------------------------------------------------------
# FlexLM's default search covers $HOME/.Xilinx/Xilinx.lic; also probe the
# Windows-side .Xilinx and Downloads in case the file landed there.
for lic in \
    "$HOME/.Xilinx/Xilinx.lic" \
    "/mnt/c/Users/kubew/.Xilinx/Xilinx.lic" \
    "/mnt/c/Users/kubew/Downloads/Xilinx.lic" \
    "/mnt/c/Users/kubew/Downloads/Xilinx_lic.lic"
do
    if [ -f "$lic" ]; then
        export XILINXD_LICENSE_FILE="$lic"
        echo "Using license: $lic" | tee /tmp/vivado_impl.log
        break
    fi
done

if [ -z "$XILINXD_LICENSE_FILE" ]; then
    {
        echo "ERROR: no Xilinx.lic found. Generate a free Vivado WebPACK license at"
        echo "  https://www.xilinx.com/getlicense"
        echo "  Node-locked, hostids (space-separated):"
        echo "    cc47401e3df6 00155dc5acf9 268ca7d9ffd8"
        echo "  (Windows physical MAC + WSL eth0 + WSL docker0, so it works in WSL)"
        echo "  Save it to ~/.Xilinx/Xilinx.lic (WSL home), then relaunch."
    } > /tmp/vivado_impl.log
    exit 1
fi

cd /mnt/c/Users/kubew/grx930/c930/synth_xilinx || exit 1
exec make impl >> /tmp/vivado_impl.log 2>&1
