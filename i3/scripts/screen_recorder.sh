#!/bin/bash

PID_FILE="/tmp/screen_recorder.pid"

# Function to start recording
start_recording() {
  slop=$(slop -f "%x %y %w %h %g %i") || exit 1
  read -r X Y W H G ID <<<"$slop"
  # Ensure width and height are even numbers
  W=$((W + W % 2)) # Round up to the nearest even number
  H=$((H + H % 2)) # Round up to the nearest even number

  # Get the default sink name
  DEFAULT_SINK=$(pactl info | grep 'Default Sink' | cut -d ' ' -f3)
  MONITOR_SOURCE="${DEFAULT_SINK}.monitor"

  # Start ffmpeg in the background and save its PID
  ffmpeg -f x11grab -s "$W"x"$H" -i :0.0+$X,$Y -f pulse -i "$MONITOR_SOURCE" -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 192k -async 1 ~/Videos/$(date +%Y-%m-%d-%H%M%S)-screen-recording.mp4 &
  echo $! >"$PID_FILE"
  notify-send "Screen Recording" "Recording started."
}

# Function to stop recording
stop_recording() {
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")"
    rm "$PID_FILE"
    notify-send "Screen Recording" "Recording stopped and saved."
  else
    echo "No screen recording is currently running."
  fi
}

# Check if the recording is already in progress
if [ -f "$PID_FILE" ]; then
  stop_recording
else
  start_recording
fi
