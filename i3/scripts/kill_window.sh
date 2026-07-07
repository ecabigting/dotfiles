# # Get the active window's class name
# active_window_class=$(xdotool getactivewindow getwindowclassname)
#
# # Specify the application you want to protect
# protected_app1="xfreerdp"
# protected_app2="steam_app_0xx"
#
# # Check if the active window is not one of the protected applications
# if [[ "$active_window_class" != *"$protected_app1"* && "$active_window_class" != *"$protected_app2"* ]]; then
#   i3-msg kill
# fi

# Get IDs and properties of the active window
active_win_id=$(xdotool getactivewindow)
active_win_class=$(xdotool getwindowclassname "$active_win_id")
active_win_title=$(xdotool getwindowname "$active_win_id")

# Define protected classes and titles
protected_classes=("xfreerdp" "steam_app_0xx")
protected_titles=("Arcadia Client" "Another Title")

# Function to check if a value is in array
in_array() {
  local val="$1"
  shift
  for i; do [[ "$val" == *"$i"* ]] && return 0; done
  return 1
}

# Check if current window is protected by class or title
if ! in_array "$active_win_class" "${protected_classes[@]}" &&
  ! in_array "$active_win_title" "${protected_titles[@]}"; then
  i3-msg kill
fi
