# Get the active window's class name
active_window_class=$(xdotool getactivewindow getwindowclassname)

# Specify the application you want to protect
protected_app="xfreerdp"

# Check if the active window is not the protected application
if [[ "$active_window_class" != *"$protected_app"* ]]; then
  i3-msg kill
fi
