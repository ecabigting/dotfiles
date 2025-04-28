-- Pull in the wezterm API
local wezterm = require 'wezterm'
local mux = wezterm.mux

-- In newer versions of wezterm, use the config_builder which will
-- help provide clearer error messages
if wezterm.config_builder then
  config = wezterm.config_builder()
end

-- Set default domain to WSL Ubuntu
config.default_domain = 'WSL:archlinux'
config.default_cwd = "/home/stifmiester/"

config.font = wezterm.font( 'MesloLGLDZ Nerd Font Mono', {weight = 'Bold',stretch = "UltraCondensed"} )
config.font_size = 11
-- For example, changing the color scheme:
config.color_scheme = 'Catppuccin Mocha'

-- Transparent Background
config.window_background_opacity = 0.9  -- Adjust this value as needed
--config.win32_system_backdrop = "Acrylic" -- Add blur

-- Set windows Borderless and allows resizing with windows key + arrow
config.window_decorations = "RESIZE"

-- CLose no confirmation
config.window_close_confirmation = 'NeverPrompt'

-- Disable tab
config.enable_tab_bar = false

config.front_end = "WebGpu"

-- set fullscreen on startup
wezterm.on('gui-startup', function(cmd)
  local tab, pane, window = mux.spawn_window(cmd or {})
  window:gui_window():maximize()
end)

-- and finally, return the configuration to wezterm
return config