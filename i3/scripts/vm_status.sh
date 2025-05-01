#!/bin/bash

# Set the IP address of your Windows VM
VM_IP="xxx.xxx.xxx.xxx" # Replace this with the actual IP address of your VM

# Set the name of your VM as it appears in Virt-Manager
VM_NAME="dirtydirtyvm" # Replace this with the actual name of your VM

# Detect click events
case $BLOCK_BUTTON in
1) # Left click
  # Attempt to start the VM via virsh
  if virsh --connect qemu:///system domstate "$VM_NAME" &>/dev/null; then
    VM_STATE=$(virsh --connect qemu:///system domstate "$VM_NAME")
    if [[ "$VM_STATE" != "running" ]]; then
      # If not running, start the VM
      virsh --connect qemu:///system start "$VM_NAME"
    fi
  fi

  # Open Virt-Manager and connect directly to the VM
  i3-msg workspace "5:"
  virt-manager --connect qemu:///system --show-domain-console "$VM_NAME" &
  ;;
esac

# Ping the VM to check if it's online
if ping -c 1 -W 1 "$VM_IP" &>/dev/null; then
  # If online, display a green computer icon
  echo -e "<span color='green'>󰍹 </span>" # Nerd Font icons for computer and checkmark
else
  # If offline, display a red computer icon
  echo -e "<span color='red'>󰶐 </span>" # Nerd Font icons for computer and cross
fi
