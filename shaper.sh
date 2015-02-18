#!/bin/bash

# Some settings
set -x
IFNAME=$1
IFSTATUS=$2
MAX_UPLOAD=100
MAX_UPLOAD_PERCENT=0.9
LOCALNET_IPV4=192.168.1.0/24
LOCALNET_IPV6=fe80::

# Setup forwarding
if [[ $IFSTATUS == "up" ]]; then
  sysctl net.ipv4.ip_forward=1
  sysctl net.ipv6.conf.default.forwarding=1
  sysctl net.ipv6.conf.all.forwarding=1

  # Use HTB (Hierarchical Token Bucket) as the default qdisc
  CLASS_3_SPEED=$(bc <<< $MAX_UPLOAD*$MAX_UPLOAD_PERCENT)
  CLASS_4_SPEED=$(bc <<< $MAX_UPLOAD-$CLASS_3_SPEED)
  tc qdisc del dev $IFNAME root
  tc qdisc add dev $IFNAME root handle 1: htb default 112
  tc class add dev $IFNAME parent 1: classid 1:1 htb rate 1gbit ceil 1gbit
  tc class add dev $IFNAME parent 1:0 classid 1:10 htb rate 999mbit ceil 1gbit
  tc class add dev $IFNAME parent 1:0 classid 1:11 htb rate ${MAX_UPLOAD}kbps ceil ${MAX_UPLOAD}kbps
  tc class add dev $IFNAME parent 1:1 classid 1:111 htb rate ${CLASS_3_SPEED}kbps ceil ${MAX_UPLOAD}kbps
  tc class add dev $IFNAME parent 1:1 classid 1:112 htb rate ${CLASS_4_SPEED}kbps ceil ${MAX_UPLOAD}kbps

  # Setup iptables-based filtering
  tc filter add dev $IFNAME protocol ip parent 1: prio 1 handle 1 fw flowid 1:10   # Local traffic
  tc filter add dev $IFNAME protocol ip parent 1: prio 2 handle 2 fw flowid 1:11   # Priority traffic
  tc filter add dev $IFNAME protocol ip parent 1: prio 3 handle 3 fw flowid 1:111  # Important traffic
  tc filter add dev $IFNAME protocol ip parent 1: prio 4 handle 4 fw flowid 1:112  # All the rest

  # Setup SFQ on all classes
  tc qdisc add dev $IFNAME parent 1:10 handle 10: fq_codel
  tc qdisc add dev $IFNAME parent 1:11 handle 11: fq_codel
  tc qdisc add dev $IFNAME parent 1:111 handle 111: fq_codel
  tc qdisc add dev $IFNAME parent 1:112 handle 112: fq_codel

  # Add iptables rules to classify packets
  function setup_iptables() {
    CMD=$1
    LOCALNET=$2
    $CMD -t mangle -F
    $CMD -t mangle -X
    $CMD -A POSTROUTING -t mangle -o $IFNAME -d $LOCALNET -j MARK --set-mark 1
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p icmp -j MARK --set-mark 2
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p udp --dport 53 -j MARK --set-mark 2
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK RST -j MARK --set-mark 2
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK FIN,ACK -j MARK --set-mark 2
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK SYN,ACK -j MARK --set-mark 2
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK RST,ACK -j MARK --set-mark 2
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK ACK -m length --length 0:40 -j MARK --set-mark 2
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 53 -j MARK --set-mark 2
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 22 -j MARK --set-mark 3
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p tcp --sport 22 -j MARK --set-mark 3
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 80 -j MARK --set-mark 3
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 443 -j MARK --set-mark 3
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p tcp --dport 5001 -j MARK --set-mark 3
    $CMD -A POSTROUTING -t mangle -o $IFNAME -p udp --dport 5001 -j MARK --set-mark 3
  }
  setup_iptables iptables $LOCALNET_IPV4
  setup_iptables ip6tables $LOCALNET_IPV6
elif [[ $IFSTATUS == "down" ]]; then
  tc qdisc del dev $IFNAME root
  iptables -t mangle -F
  iptables -t mangle -X
  ip6tables -t mangle -F
  ip6tables -t mangle -X
else
  echo "Invalid interface status: $IFSTATUS"
fi
