#!/bin/bash
echo " --Starting virtual machine --"
virsh --connect qemu:///system start win11-base

# Wait for VM to boot (adjust sleep time if needed)
sleep 60

echo "-- Focus on WS 5 -- "
i3-msg workspace "5"

echo "-- Starting xfreerdp --"
xfreerdp3 \
  -grab-keyboard \
  /v:xxx.xxx.xxx.xxx \
  /size:100% \
  /u:xxx.xxx.xx \
  /p:yyy.yyyy.yyy \
  /cert:ignore \
  /d: \
  /dynamic-resolution \
  /gfx:avc444
# /progressive:on &
disown # Detach from the script’s shell
