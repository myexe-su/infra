#!/bin/bash
if ! ping -c 3 -W 3 192.168.1.1 > /dev/null 2>&1; then
    logger -t network-watchdog "gateway unreachable, resetting Wi-Fi"
    nmcli radio wifi off
    sleep 2
    nmcli radio wifi on
fi
