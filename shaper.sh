#!/bin/bash

# Usage: shaper.sh <interface> [up|down]
#
# This script is intended to be used as a NetworkManager-Dispatcher script, see
# networkmanager(8) for more information.

# Show executed commands for easier debugging
set -x

# Store command arguments
IFNAME=$1        # Interface name
IFSTATUS=$2      # Interface status (up or down)

####################
# General settings #
####################

# Maximum bandwidth allocated to the uplink, in kbps.
#
# Note that if this is greater than the available bandwidth, the traffic will
# be shaped by the network's limiting node instead of this script (usually your
# ISP's modem/router).
MAX_UPLOAD=100

# Percentage of the maximum upload bandwidth reserved for each class:
#  * Class 1 for local (or really, really important) traffic
#  * Class 2 for priority traffic (ACKs, DNS resolution,...)
#  * Class 3 for important traffic (SSH, web browsing,...)
#  * Class 4 for all other traffic
MAX_CLASS_2_PERCENT=0.1
MAX_CLASS_3_PERCENT=0.8
MAX_CLASS_4_PERCENT=0.1

# Local networks to use when filtering local packets.
LOCALNET_IPV4=192.168.1.0/24
LOCALNET_IPV6=fe80::

###############
# Main script #
###############

# Utility function to filter packets on both IPv4 and IPv6 traffic.
function ip64tables() {
  iptables $*
  ip6tables $*
}

# If the interface is being brought up, then clear all existing rules and setup
# traffic shaping for this interface.
if [[ $IFSTATUS == "up" ]]; then

  # Make sure forwarding is enabled
  sysctl net.ipv4.ip_forward=1
  sysctl net.ipv6.conf.default.forwarding=1
  sysctl net.ipv6.conf.all.forwarding=1

  # Setup HTB (Hierarchical Token Bucket) to limit bandwidth for each class of
  # traffic, as described above.
  CLASS_2_SPEED=$(bc <<< $MAX_UPLOAD*$MAX_CLASS_2_PERCENT)
  CLASS_3_SPEED=$(bc <<< $MAX_UPLOAD*$MAX_CLASS_3_PERCENT)
  CLASS_4_SPEED=$(bc <<< $MAX_UPLOAD*$MAX_CLASS_4_PERCENT)
  tc qdisc del dev $IFNAME root
  tc qdisc add dev $IFNAME root handle 1: htb default 112
  tc class add dev $IFNAME parent 1: classid 1:1 htb rate 1gbit ceil 1gbit
  tc class add dev $IFNAME parent 1:0 classid 1:10 htb rate 999mbit ceil 1gbit
  tc class add dev $IFNAME parent 1:0 classid 1:11 htb rate ${MAX_UPLOAD}kbps ceil ${MAX_UPLOAD}kbps
  tc class add dev $IFNAME parent 1:1 classid 1:110 htb rate ${CLASS_2_SPEED}kbps ceil ${MAX_UPLOAD}kbps
  tc class add dev $IFNAME parent 1:1 classid 1:111 htb rate ${CLASS_3_SPEED}kbps ceil ${MAX_UPLOAD}kbps
  tc class add dev $IFNAME parent 1:1 classid 1:112 htb rate ${CLASS_4_SPEED}kbps ceil ${MAX_UPLOAD}kbps
  tc qdisc add dev $IFNAME parent 1:10 handle 10: fq_codel
  tc qdisc add dev $IFNAME parent 1:110 handle 110: fq_codel
  tc qdisc add dev $IFNAME parent 1:111 handle 111: fq_codel
  tc qdisc add dev $IFNAME parent 1:112 handle 112: fq_codel

  # Offload all packet filtering to iptables (I found it much easier to use
  # than tc filters).
  tc filter add dev $IFNAME protocol ip parent 1: prio 1 handle 1 fw flowid 1:10   # Local traffic
  tc filter add dev $IFNAME protocol ip parent 1: prio 2 handle 2 fw flowid 1:110  # Priority traffic
  tc filter add dev $IFNAME protocol ip parent 1: prio 3 handle 3 fw flowid 1:111  # Important traffic
  tc filter add dev $IFNAME protocol ip parent 1: prio 4 handle 4 fw flowid 1:112  # All the rest

  # Add iptables rules to classify packets, in reverse priority order (since
  # the packet mark is overwritten on each call to --set-mark).
  ip64tables -t mangle -F
  ip64tables -t mangle -X
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p udp --dport 5001 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 5001 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 443 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 80 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --sport 22 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 22 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 53 -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK ACK -m length --length 0:40 -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK RST,ACK -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK SYN,ACK -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK FIN,ACK -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK RST -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p udp --dport 53 -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p icmp -j MARK --set-mark 2
  iptables -A POSTROUTING -t mangle -o $IFNAME -d $LOCALNET_IPV4 -j MARK --set-mark 1
  ip6tables -A POSTROUTING -t mangle -o $IFNAME -d $LOCALNET_IPV6 -j MARK --set-mark 1

# If the interface is being brought down, clear all traffic shaping rules.
elif [[ $IFSTATUS == "down" ]]; then
  tc qdisc del dev $IFNAME root
  iptables -t mangle -F
  iptables -t mangle -X
  ip6tables -t mangle -F
  ip6tables -t mangle -X

# If the status is anything else, exit with an error.
else
  echo "Invalid interface status: $IFSTATUS"
  exit 1
fi
