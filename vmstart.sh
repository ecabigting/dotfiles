#!/bin/bash
echo " --Starting virtual machine --"
virsh --connect qemu:///system start win11-base
sleep 50
echo "-- Sleeping for 50 seconds before connecting to device --"
xfreerdp3 -grab-keyboard /v:192.168.122.225 /size:100% /u: /p: /cert:ignore /d: /dynamic-resolution /gfx:avc444,progressive:on &
