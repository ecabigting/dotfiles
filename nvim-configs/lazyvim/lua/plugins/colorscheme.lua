return {
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "tokyonight-moon",
    },
  },
  {
    "folke/tokyonight.nvim",
    lazy = true,
    enabled = true,
    opts = {
      transparent = true,
      styles = {
        comments = { italic = true },
        keywords = { italic = false },
        functions = { bold = true, italic = true }, -- function names → cursive + bold
        variables = { italic = false, bold = false }, -- locals → cursive
        sidebars = "transparent",
        floats = "transparent",
      },
    },
  },
  {
    "catppuccin/nvim",
    lazy = true,
    enabled = false,
    name = "catppuccin",
    opts = {
      flavour = "auto",
      transparent_background = true,
      float = {
        transparent = true,
      },
      background = {
        light = "latte",
        dark = "frappe",
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
