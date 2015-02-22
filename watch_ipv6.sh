#!/bin/bash

watch ip6tables -L POSTROUTING -n -v -t mangle
