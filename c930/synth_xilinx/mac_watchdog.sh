#!/bin/bash
# -----------------------------------------------------------------------------
# mac_watchdog.sh -- run as root inside WSL. The Hyper-V vSwitch intermittently
# reverts eth0 to the epoch's random MAC ("does not allow mac spoofing"), which
# breaks the node-locked Vivado license (FlexNet -9,23) mid-run. This loop
# re-applies the licensed MAC and the correct default route within seconds of
# any drift. Exits once the routed checkpoint exists (flow done), or after the
# overall timeout.
# -----------------------------------------------------------------------------
MAC=00:15:5d:c5:ac:f9
GW=172.25.32.1
FINAL_DCP=/mnt/c/Users/kubew/grx930/c930/build/vivado/c930_artix7.runs/impl_1/c930_soc_top_routed.dcp
LOG=/mnt/c/Users/kubew/grx930/c930/build/vivado/mac_watchdog.log
DEADLINE=$(( $(date +%s) + 21600 ))   # 6 h cap

echo "=== mac watchdog started $(date) ===" >> "$LOG"

# FlexNet reads the first MAC it enumerates. A dummy interface carrying the
# licensed MAC keeps license checks passing even while eth0 is in a reverted
# (random-MAC) window. Idempotent; recreated here because it dies with the VM.
modprobe dummy >/dev/null 2>&1
if ! ip link show dummy0 >/dev/null 2>&1; then
    ip link add dummy0 type dummy 2>/dev/null
    ip link set dummy0 address "$MAC" 2>/dev/null
    ip link set dummy0 up 2>/dev/null
    echo "dummy0 created with licensed MAC $(date)" >> "$LOG"
fi

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if [ -f "$FINAL_DCP" ]; then
        echo "routed checkpoint present -- watchdog done $(date)" >> "$LOG"
        break
    fi
    cur=$(cat /sys/class/net/eth0/address 2>/dev/null)
    if [ "$cur" != "$MAC" ]; then
        echo "MAC drift: $cur -> $MAC $(date)" >> "$LOG"
        # Fast path: restore the MAC with the shortest possible link flap.
        # FlexNet only reads the MAC -- it does not need the lease, so do the
        # slow network re-lease separately below.
        ip link set dev eth0 down
        ip link set dev eth0 address "$MAC"
        ip link set dev eth0 up
        sleep 1
        dhcpcd -k eth0 >/dev/null 2>&1
        dhcpcd eth0 >/dev/null 2>&1
        sleep 2
        lladdr=$(ip -4 addr show dev eth0 | awk '/169\.254\./{print $2}')
        [ -n "$lladdr" ] && ip addr del "$lladdr" dev eth0 2>/dev/null
        ip route del default dev eth0 2>/dev/null
        ip route replace default via "$GW" dev eth0
        echo "healed: MAC=$(cat /sys/class/net/eth0/address) route=$(ip route show default)" >> "$LOG"
    fi
    # Also guard the default route (can be lost without MAC drift).
    if ! ip route show default 2>/dev/null | grep -q "via $GW"; then
        ip route replace default via "$GW" dev eth0 2>/dev/null
    fi
    # dummy0 can vanish if the module unloads; restore it.
    if ! ip link show dummy0 >/dev/null 2>&1; then
        modprobe dummy >/dev/null 2>&1
        ip link add dummy0 type dummy 2>/dev/null
        ip link set dummy0 address "$MAC" 2>/dev/null
        ip link set dummy0 up 2>/dev/null
    fi
    sleep 2
done
echo "=== mac watchdog exiting $(date) ===" >> "$LOG"
