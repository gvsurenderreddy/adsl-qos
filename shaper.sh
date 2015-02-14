#!/bin/bash

set -x

MAX_UPLOAD=100kbps

# Use HTB (Hierarchical Token Bucket) as the default qdisc
tc qdisc del dev enp3s0 root
tc qdisc add dev enp3s0 root handle 1: htb default 112
tc class add dev enp3s0 parent 1: classid 1:1 htb rate 1gbit ceil 1gbit
tc class add dev enp3s0 parent 1:0 classid 1:10 htb rate 999mbit ceil 1gbit
tc class add dev enp3s0 parent 1:0 classid 1:11 htb rate ${MAX_UPLOAD} ceil ${MAX_UPLOAD}
tc class add dev enp3s0 parent 1:1 classid 1:111 htb rate 90kbps ceil ${MAX_UPLOAD}
tc class add dev enp3s0 parent 1:1 classid 1:112 htb rate 10kbps ceil ${MAX_UPLOAD}

# Setup iptables-based filtering
tc filter add dev enp3s0 protocol ip parent 1: prio 1 handle 1 fw flowid 1:10   # Local traffic
tc filter add dev enp3s0 protocol ip parent 1: prio 2 handle 2 fw flowid 1:11   # Priority traffic
tc filter add dev enp3s0 protocol ip parent 1: prio 3 handle 3 fw flowid 1:111  # Important traffic
tc filter add dev enp3s0 protocol ip parent 1: prio 4 handle 4 fw flowid 1:112  # All the rest

# Add iptables rules to classify packets
iptables -t mangle -F
iptables -t mangle -X
iptables -A POSTROUTING -t mangle -o enp3s0 -d 192.168.1.0/24 -j MARK --set-mark 1
iptables -A POSTROUTING -t mangle -o enp3s0 -p icmp -j MARK --set-mark 2
iptables -A POSTROUTING -t mangle -o enp3s0 -p udp --dport 53 -j MARK --set-mark 2
iptables -A POSTROUTING -t mangle -o enp3s0 -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK RST -j MARK --set-mark 2
iptables -A POSTROUTING -t mangle -o enp3s0 -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK FIN,ACK -j MARK --set-mark 2
iptables -A POSTROUTING -t mangle -o enp3s0 -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK SYN,ACK -j MARK --set-mark 2
iptables -A POSTROUTING -t mangle -o enp3s0 -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK RST,ACK -j MARK --set-mark 2
iptables -A POSTROUTING -t mangle -o enp3s0 -p tcp --match multiport --dports 0:1024 --tcp-flags FIN,SYN,RST,ACK ACK -m length --length 0:40 -j MARK --set-mark 2
iptables -A POSTROUTING -t mangle -o enp3s0 -p tcp --dport 53 -j MARK --set-mark 2
iptables -A POSTROUTING -t mangle -o enp3s0 -p tcp --dport 22 -j MARK --set-mark 3
iptables -A POSTROUTING -t mangle -o enp3s0 -p tcp --sport 22 -j MARK --set-mark 3
iptables -A POSTROUTING -t mangle -o enp3s0 -p tcp --dport 80 -j MARK --set-mark 3
iptables -A POSTROUTING -t mangle -o enp3s0 -p tcp --dport 443 -j MARK --set-mark 3
iptables -A POSTROUTING -t mangle -o enp3s0 -p tcp --dport 5001 -j MARK --set-mark 3
iptables -A POSTROUTING -t mangle -o enp3s0 -p udp --dport 5001 -j MARK --set-mark 3

# Setup SFQ on all classes
tc qdisc add dev enp3s0 parent 1:10 handle 10: fq_codel
tc qdisc add dev enp3s0 parent 1:11 handle 11: fq_codel
tc qdisc add dev enp3s0 parent 1:111 handle 111: fq_codel
tc qdisc add dev enp3s0 parent 1:112 handle 112: fq_codel
