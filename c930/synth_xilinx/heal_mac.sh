#!/bin/bash
# -----------------------------------------------------------------------------
# heal_mac.sh -- run as root inside WSL. Restores the node-locked-license MAC
# on eth0 (fix-wsl-mac.sh can lose the boot race on a fresh VM) and repairs
# the routing state that a mid-boot MAC change leaves behind:
#   * WSL's DHCP client grants the lease but sometimes installs the IPv4LL
#     fallback as the default route instead of a via-gateway route
#   * dhcpcd's re-lease adds a stray 169.254.x IPv4LL address
# After this: eth0 has MAC 00:15:5d:c5:ac:f9, the 172.25.x DHCP address, and
# `default via 172.25.32.1`.
# -----------------------------------------------------------------------------
set -x
MAC=00:15:5d:c5:ac:f9
GW=172.25.32.1

cur=$(cat /sys/class/net/eth0/address 2>/dev/null)
if [ "$cur" != "$MAC" ]; then
    ip link set dev eth0 down
    ip link set dev eth0 address "$MAC"
    ip link set dev eth0 up
    sleep 3
    dhcpcd -k eth0 >/dev/null 2>&1
    sleep 1
    dhcpcd eth0 >/dev/null 2>&1
    sleep 4
fi

# Stray IPv4LL address from the re-lease (delete by exact address).
lladdr=$(ip -4 addr show dev eth0 | awk '/169\.254\./{print $2}')
[ -n "$lladdr" ] && ip addr del "$lladdr" dev eth0 2>/dev/null

# Default route: replace an IPv4LL link-scope default with a via-gateway one.
ip route del default dev eth0 2>/dev/null
ip route replace default via "$GW" dev eth0

echo "heal done: MAC=$(cat /sys/class/net/eth0/address) addr=$(ip -4 addr show dev eth0 | awk '/172\.25/{print $2}') route=$(ip route show default)"

# FlexNet insurance: a dummy interface with the licensed MAC, so license
# checks pass even if eth0 drifts again (module recreate is idempotent).
modprobe dummy >/dev/null 2>&1
if ! ip link show dummy0 >/dev/null 2>&1; then
    ip link add dummy0 type dummy 2>/dev/null
    ip link set dummy0 address 00:15:5d:c5:ac:f9 2>/dev/null
    ip link set dummy0 up 2>/dev/null
fi
