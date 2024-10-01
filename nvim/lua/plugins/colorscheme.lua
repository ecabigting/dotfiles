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
      flavour = "frappe",
      transparent_background = true,
      style = {
        functions = {
          "italic",
          "bold",
        },
      },
      integrations = {
        indent_blankline = { enabled = true, scope_color = "pink", colored_indent_levels = true },
      },
    },
  },
}
