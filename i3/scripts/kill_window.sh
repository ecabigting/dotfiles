# Get the active window's class name
active_window_class=$(xdotool getactivewindow getwindowclassname)

# Specify the application you want to protect
protected_app1="xfreerdp"
protected_app2="steam_proton"

# Check if the active window is not one of the protected applications
if [[ "$active_window_class" != *"$protected_app1"* && "$active_window_class" != *"$protected_app2"* ]]; then
  i3-msg kill
fi
