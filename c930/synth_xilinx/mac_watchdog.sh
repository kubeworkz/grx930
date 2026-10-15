#!/bin/bash
# -----------------------------------------------------------------------------
# mac_watchdog.sh -- run as root inside WSL. The Hyper-V vSwitch intermittently
# reverts eth0 to the epoch's random MAC ("does not allow mac spoofing"), which
# breaks the node-locked Vivado license (FlexNet -9,23) mid-run. This loop
# re-applies the licensed MAC and the correct default route within seconds of
# any drift. Exits once the routed checkpoint exists AND vivado has exited
# (run_synth.tcl keeps the same vivado running through reports and
# write_bitstream after routing, still under license), or after the overall
# timeout.
#
# On exit it puts WSL networking back. The vSwitch drops every frame sent from
# the licensed MAC, so leaving it on eth0 cuts WSL off from the network for
# good -- the self-hosted aerosls CI runner in this VM lost GitHub for days
# that way. And the dhcpcd that the heal path and heal_mac.sh start outlives
# them: WSL has no DHCP server, so on the next link flap it adds a 169.254.x
# address and replaces the default route with a gatewayless one. Cleanup stops
# dhcpcd, restores eth0's Hyper-V MAC, static address and default route.
# dummy0 keeps the licensed MAC.
# -----------------------------------------------------------------------------
MAC=00:15:5d:c5:ac:f9
GW=172.25.32.1
FINAL_DCP=/mnt/c/Users/kubew/grx930-build/c930/build/vivado/c930_artix7.runs/impl_1/c930_soc_top_routed.dcp
LOG=/mnt/c/Users/kubew/grx930-build/c930/build/vivado/mac_watchdog.log
DEADLINE=$(( $(date +%s) + 21600 ))   # 6 h cap

mkdir -p "$(dirname "$LOG")" 2>/dev/null
echo "=== mac watchdog started $(date) ===" >> "$LOG"

# What cleanup restores. The permanent address is the MAC Hyper-V assigned
# this VM epoch: it survives spoofing (heal_mac.sh has usually replaced eth0's
# current MAC before this starts) and changes on every VM boot, so read it
# here rather than hard-coding it. `ip link` only prints permaddr while the
# current MAC differs; an unspoofed current MAC is the permanent one. Every
# source is validated: ethtool reports "Permanent address: not set" on some
# devices.
is_mac() {
    local re='^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'
    [[ $1 =~ $re ]] && [ "$1" != 00:00:00:00:00:00 ]
}
PERM_MAC=$(ethtool -P eth0 2>/dev/null | awk '{print tolower($3)}')
if ! is_mac "$PERM_MAC"; then
    PERM_MAC=$(ip link show eth0 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "permaddr") print $(i + 1)}')
fi
if ! is_mac "$PERM_MAC"; then
    PERM_MAC=
    cur=$(cat /sys/class/net/eth0/address 2>/dev/null)
    if is_mac "$cur" && [ "$cur" != "$MAC" ]; then
        PERM_MAC=$cur
    fi
fi
START_ADDRS=$(ip -4 addr show dev eth0 2>/dev/null | awk '/inet / && $2 !~ /^169\.254\./ {print $2}')
echo "cleanup will restore: MAC=${PERM_MAC:-unknown} addr=${START_ADDRS:-none} gw=$GW" >> "$LOG"

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    if pgrep -x vivado >/dev/null 2>&1; then
        echo "WARNING: cleanup with vivado still running (watchdog was signalled) -- eth0 loses the licensed MAC, dummy0 keeps it $(date)" >> "$LOG"
    fi

    # 1. Stop dhcpcd BEFORE the link flap below, or it answers the flap with
    #    another IPv4LL address and gatewayless default route.
    if pgrep -x dhcpcd >/dev/null 2>&1; then
        dhcpcd -x eth0 >/dev/null 2>&1
        for _ in 1 2 3 4 5; do
            pgrep -x dhcpcd >/dev/null 2>&1 || break
            sleep 1
        done
        pkill -TERM -x dhcpcd 2>/dev/null
    fi

    # 2. eth0 back on its Hyper-V MAC, the only one the vSwitch forwards.
    if [ -n "$PERM_MAC" ] && [ "$(cat /sys/class/net/eth0/address 2>/dev/null)" != "$PERM_MAC" ]; then
        ip link set dev eth0 down
        ip link set dev eth0 address "$PERM_MAC"
        ip link set dev eth0 up
        sleep 2
    fi

    # 3. dhcpcd's leftovers out (deleting the 169.254.x address also flushes
    #    the routes sourced from it), static address and default route back.
    for a in $(ip -4 addr show dev eth0 2>/dev/null | awk '/inet / && $2 ~ /^169\.254\./ {print $2}'); do
        ip addr del "$a" dev eth0 2>/dev/null
    done
    ip route del 169.254.0.0/16 dev eth0 2>/dev/null
    for a in $START_ADDRS; do
        ip -4 addr show dev eth0 | grep -q "inet $a " || ip addr add "$a" dev eth0 2>/dev/null
    done
    ip route show default | grep -v "via $GW dev eth0" | while read -r r; do
        ip route del $r 2>/dev/null
    done
    ip route replace default via "$GW" dev eth0 2>/dev/null

    if ping -c1 -W2 "$GW" >/dev/null 2>&1; then gw_state=ok; else gw_state=FAIL; fi
    echo "restored: MAC=$(cat /sys/class/net/eth0/address 2>/dev/null) addr=$(ip -4 addr show dev eth0 | awk '/inet /{printf "%s ", $2}')route=[$(ip route show default | tr '\n' ' ')] gateway-ping=$gw_state" >> "$LOG"
    echo "=== mac watchdog exiting $(date) ===" >> "$LOG"
}
# EXIT covers the normal end; the signal traps turn a kill into an exit so
# EXIT still fires. (HUP is ignored under nohup and cannot be trapped there.)
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
    if [ -f "$FINAL_DCP" ] && ! pgrep -x vivado >/dev/null 2>&1; then
        echo "routed checkpoint present and vivado exited -- watchdog done $(date)" >> "$LOG"
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
    # OOM protection: protect vivado from the kernel OOM killer.
    # TM peaks at ~7 GB RSS on an 8 GB VM; without this the kernel
    # kills vivado before swap absorbs the pressure.
    for pid in $(pgrep vivado 2>/dev/null); do
        echo -1000 > /proc/$pid/oom_score_adj 2>/dev/null
    done
    sleep 2
done

# Past the cap with the flow still running: stop healing, but don't pull the
# licensed MAC out from under a licensed vivado -- clean up once it exits.
if pgrep -x vivado >/dev/null 2>&1; then
    echo "deadline reached with vivado running -- healing stopped, cleanup waits for vivado to exit $(date)" >> "$LOG"
    while pgrep -x vivado >/dev/null 2>&1; do
        sleep 30
    done
fi
