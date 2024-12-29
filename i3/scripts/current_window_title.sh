#!/bin/bash
# Get the current window title
title=$(xdotool getactivewindow getwindowname)
echo "$title"
