#!/bin/bash

# Get the current day of the week (0-6, Monday-Sunday)
today=$(date +%u)

# Get the current hour (24-hour format)
current_hour=$(date +%H)

# Check if it's a weekday (Monday to Friday) and the hour is less than 18 (6 PM)
if [ $(date +%u) -lt 6 ] && [ $(date +%H) -lt 18 ]; then
  # It's a weekday before 6 PM
  echo "It's a weekday before 6 PM"
  # ~/.config/vmstart.sh
  # sleep 3 
  # teams
  # firefox
else
  # It's either weekend or after 6 PM
  echo "It's either weekend or after 6 PM"
fi