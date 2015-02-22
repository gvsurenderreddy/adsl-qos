#!/bin/bash

watch iptables -L POSTROUTING -n -v -t mangle
