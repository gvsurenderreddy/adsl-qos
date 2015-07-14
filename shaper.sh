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
MAX_UPLOAD=85

# Percentage of the maximum upload bandwidth reserved for each class:
#  * Class 1 for local (or really, really important) traffic
#  * Class 2 for priority traffic (ACKs, DNS resolution,...)
#  * Class 3 for important traffic (SSH, web browsing,...)
#  * Class 4 for all other traffic
MAX_CLASS_2_PERCENT=0.1
MAX_CLASS_3_PERCENT=0.8
MAX_CLASS_4_PERCENT=0.1
MAX_CLASS_5_PERCENT=0.0

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

  # Compute speeds for each class
  CLASS_2_SPEED=$(bc <<< $MAX_UPLOAD*$MAX_CLASS_2_PERCENT)
  CLASS_3_SPEED=$(bc <<< $MAX_UPLOAD*$MAX_CLASS_3_PERCENT)
  CLASS_4_SPEED=$(bc <<< $MAX_UPLOAD*$MAX_CLASS_4_PERCENT)
  CLASS_5_SPEED=$(bc <<< $MAX_UPLOAD*$MAX_CLASS_5_PERCENT)

  # Create or replace the root qdisc by an HTB qdisc, defaulting to the class
  # with the least important priority (1:112).
  tc qdisc del dev $IFNAME root
  tc qdisc add dev $IFNAME root handle 1: htb default 112

  # Create the root classs, i.e. the ones that are attached to the root qdisc
  # directly. Root classes cannot borrow bandwidth from another root class, so
  # they are well-suited for separating local and internet traffic.
  #
  # Each tc class is written x:y, where x is the qdisc id, and y the class id.
  # Here, we create one class (1:10) for local traffic and another (1:11) for
  # internet traffic.
  tc class add dev $IFNAME parent 1: classid 1:10 htb rate 1gbit
  tc class add dev $IFNAME parent 1: classid 1:11 htb rate ${MAX_UPLOAD}kbps

  # The local traffic should be more than fine without supervision, but the
  # internet traffic needs some prioritization. We create subclasses of the
  # root internet class, each able to borrow from the others if there is enough
  # available bandwidth.
  tc class add dev $IFNAME parent 1:11 classid 1:110 htb rate ${CLASS_2_SPEED}kbps ceil ${MAX_UPLOAD}kbps
  tc class add dev $IFNAME parent 1:11 classid 1:111 htb rate ${CLASS_3_SPEED}kbps ceil ${MAX_UPLOAD}kbps
  tc class add dev $IFNAME parent 1:11 classid 1:112 htb rate ${CLASS_4_SPEED}kbps ceil ${MAX_UPLOAD}kbps
  tc class add dev $IFNAME parent 1:11 classid 1:113 htb rate 5kbps ceil ${MAX_UPLOAD}kbps

  # Add SFQ (Stochastic Fairness Queuing) to each leaf
  tc qdisc add dev $IFNAME parent 1:10 handle 10: sfq perturb 10
  tc qdisc add dev $IFNAME parent 1:110 handle 110: sfq perturb 10
  tc qdisc add dev $IFNAME parent 1:111 handle 111: sfq perturb 10
  tc qdisc add dev $IFNAME parent 1:112 handle 112: sfq perturb 10
  tc qdisc add dev $IFNAME parent 1:113 handle 113: sfq perturb 10

  # Direct packets to the relevant class
  tc filter add dev $IFNAME parent 1: prio 100 handle 1 fw flowid 1:10
  tc filter add dev $IFNAME parent 1: prio 300 handle 2 fw flowid 1:110
  tc filter add dev $IFNAME parent 1: prio 400 handle 3 fw flowid 1:111
  tc filter add dev $IFNAME parent 1: prio 500 handle 4 fw flowid 1:112
  tc filter add dev $IFNAME parent 1: prio 600 handle 5 fw flowid 1:113

  # Clear iptables rules
  ip64tables -t mangle -F
  ip64tables -t mangle -X
  ip64tables -t raw -F
  ip64tables -t raw -X

  # Priority 4: Match low-priority packets
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -j MARK --set-mark 4

  # Priority 3: Match intermediate-priority packets
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p gre -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 1723 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --sport 1723 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 5001 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p udp --dport 5001 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 993 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 443 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --sport 443 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 4443 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --sport 4443 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 80 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --sport 80 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 22 -j MARK --set-mark 3
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --sport 22 -j MARK --set-mark 3

  # Priority 2: Match high-priority packets (ICMP, DNS and small FIN/ACK/SYN)
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 53 -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p udp --dport 53 -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --tcp-flags FIN,SYN,RST,ACK ACK -m length --length 0:40 -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --tcp-flags FIN,SYN,RST,ACK RST,ACK -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --tcp-flags FIN,SYN,RST,ACK SYN,ACK -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --tcp-flags FIN,SYN,RST,ACK FIN,ACK -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p tcp --tcp-flags FIN,SYN,RST,ACK RST -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p udp --dport 53 -j MARK --set-mark 2
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -p icmp -j MARK --set-mark 2

  # Priority 5: Bittorrent traffic
  ip64tables -A POSTROUTING -t mangle -o $IFNAME -m owner --uid-owner transmission -j MARK --set-mark 5

  # Priority 1: Match local packets
  iptables -A POSTROUTING -t mangle -o $IFNAME -d $LOCALNET_IPV4 -j MARK --set-mark 1
  ip6tables -A POSTROUTING -t mangle -o $IFNAME -d $LOCALNET_IPV6 -j MARK --set-mark 1

  # Packet tracing
  # ip64tables -A PREROUTING -t raw -p tcp --dport 5001 -j TRACE
  # ip64tables -A OUTPUT -t raw -o $IFNAME -p tcp --dport 5001 -j TRACE

# If the interface is being brought down, clear all traffic shaping rules.
elif [[ $IFSTATUS == "down" ]]; then
  tc qdisc del dev $IFNAME root
  ip64tables -t mangle -F
  ip64tables -t mangle -X
  ip64tables -t raw -F
  ip64tables -t raw -X

# If the status is anything else, exit with an error.
else
  echo "Invalid interface status: $IFSTATUS"
  exit 1
fi
