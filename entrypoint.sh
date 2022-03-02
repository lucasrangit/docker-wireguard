#!/bin/bash
set -o xtrace
set -e

# Run PIA setup script
/opt/piavpn-manual/run_setup.sh

default_route_ip=$(ip route | grep default | awk '{print $3}')
if [[ -z "$default_route_ip" ]]; then
    echo "No default route configured" >&2
    exit 1
fi

configs=`find /etc/wireguard -type f -printf "%f\n"`
if [[ -z "$configs" ]]; then
    echo "No configuration files found in /etc/wireguard" >&2
    exit 1
fi

config=`echo $configs | head -n 1`
interface="${config%.*}"

if [[ "$(cat /proc/sys/net/ipv4/conf/all/src_valid_mark)" != "1" ]]; then
    echo "sysctl net.ipv4.conf.all.src_valid_mark=1 is not set" >&2
    exit 1
fi

# The net.ipv4.conf.all.src_valid_mark sysctl is set when running the Docker container, so don't have WireGuard also set it
sed -i "s:sysctl -q net.ipv4.conf.all.src_valid_mark=1:echo Skipping setting net.ipv4.conf.all.src_valid_mark:" /usr/bin/wg-quick
wg-quick up $interface

# IPv4 kill switch: traffic must be either (1) to the WireGuard interface, (2) marked as a WireGuard packet, (3) to a local address, or (4) to the Docker network
docker_network="$(ip -o addr show dev eth0 | awk '$3 == "inet" {print $4}')"
docker_network_rule=$([ ! -z "$docker_network" ] && echo "! -d $docker_network" || echo "")
iptables -I OUTPUT ! -o $interface -m mark ! --mark $(wg show $interface fwmark) -m addrtype ! --dst-type LOCAL $docker_network_rule -j REJECT

# IPv6 kill switch: traffic must be either (1) to the WireGuard interface, (2) marked as a WireGuard packet, (3) to a local address, or (4) to the Docker network
docker6_network="$(ip -o addr show dev eth0 | awk '$3 == "inet6" {print $4}')"
if [[ "$docker6_network" ]]; then
    docker6_network_rule=$([ ! -z "$docker6_network" ] && echo "! -d $docker6_network" || echo "")
    ip6tables -I OUTPUT ! -o $interface -m mark ! --mark $(wg show $interface fwmark) -m addrtype ! --dst-type LOCAL $docker6_network_rule -j REJECT
else
    echo "Skipping IPv6 kill switch setup since IPv6 interface was not found" >&2
fi

# Support LOCAL_NETWORK environment variable, which was replaced by LOCAL_SUBNET
if [[ -z "$LOCAL_SUBNET" && "$LOCAL_NETWORK" ]]; then
    LOCAL_SUBNET=$LOCAL_NETWORK
fi

if [[ "$LOCAL_SUBNET" ]]; then
    echo "Allowing traffic to local subnet ${LOCAL_SUBNET}" >&2
    ip route add $LOCAL_SUBNET via $default_route_ip
    iptables -I OUTPUT -d $LOCAL_SUBNET -j ACCEPT
fi

shutdown () {
    wg-quick down $interface
    exit 0
}

trap shutdown SIGTERM SIGINT SIGQUIT

sleep infinity &
wait $!
