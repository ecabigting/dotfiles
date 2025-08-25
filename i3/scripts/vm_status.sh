#!/bin/bash

# Set the IP address of your Windows VM
VM_IP="xxx.xxx.xx.xxx" # Replace this with the actual IP address of your VM

color="#cad3f5"
bgcolor="#1e203080"
vmStatus="<span>󰶐</span>"

# Ping the VM to check if it's online (with a timeout)
if ping -c 1 -W 1 "$VM_IP" &>/dev/null; then
  # If online, display a green computer icon
  # echo "<span color='green'>󰍹</span>" # Nerd Font icons for computer and checkmark
  color="#a6da95"
  vmStatus="<span>󰨇</span>"
fi

echo ${vmStatus}
echo "" # short text
echo ${color}
echo ${bgcolor}
