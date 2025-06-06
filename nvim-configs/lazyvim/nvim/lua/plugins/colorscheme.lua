return {
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "catppuccin",
    },
  },
  {
    "catppuccin/nvim",
    lazy = true,
    name = "catppuccin",
    opts = {
      flavour = "mocha",
      transparent_background = true,
      background = {
        light = "latte",
        dark = "mocha",
      },
      styles = {
        keywords = { "bold", "italic" },
      },
      integrations = {
        indent_blankline = { enabled = true, scope_color = "pink", colored_indent_levels = true },
        blink_cmp = true,
      },
    },
  },
}
