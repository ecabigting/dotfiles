#!/bin/bash

# Set the IP address of your Windows VM
VM_IP="192.168.1.24" # Replace this with the actual IP address of your VM

# Set the name of your VM as it appears in Virt-Manager
VM_NAME="win11-base" # Replace this with the actual name of your VM

# Detect click events
case $BLOCK_BUTTON in
1) # Left click
  # Start the VM if not running
  (
    if virsh --connect qemu:///system domstate "$VM_NAME" &>/dev/null; then
      VM_STATE=$(virsh --connect qemu:///system domstate "$VM_NAME")
      if [[ "$VM_STATE" != "running" ]]; then
        # If not running, start the VM
        virsh --connect qemu:///system start "$VM_NAME" &>/dev/null
      fi
    fi

    # Open Virt-Manager and connect directly to the VM in the background
    i3-msg -q workspace "5:" &
    i3-msg -q exec "virt-manager --connect qemu:///system --show-domain-console '$VM_NAME'" &
  ) &
  ;;
esac

# Ping the VM to check if it's online (with a timeout)
if ping -c 1 -W 1 "$VM_IP" &>/dev/null; then
  # If online, display a green computer icon
  echo "<span color='green'>󰍹 </span>VM" # Nerd Font icons for computer and checkmark
else
  # If offline, display a red computer icon
  echo "<span color='red'>󰶐 </span>VM" # Nerd Font icons for computer and cross
fi
