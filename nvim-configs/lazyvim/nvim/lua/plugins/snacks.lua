return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  ---@type snacks.Config
  opts = {
    -- your configuration comes here
    -- or leave it empty to use the default settings
    -- refer to the configuration section below
    bigfile = { enabled = true },
    dashboard = { enabled = false },
    explorer = {
      enabled = true,
      replace_netrw = true,
    },
    indent = { enabled = true },
    input = { enabled = true },
    picker = {
      sources = {
        explorer = {
          hidden = true,
          ignored = true,
          exclude = { "node_modules", "dist", ".git", ".next", ".expo" },
          win = {
            list = {
              keys = {
                ["<leader>/"] = false,
              },
            },
          },
        },
        files = {
          hidden = true,
          ignored = true,
          exclude = { "node_modules", "dist", ".git", ".next", ".expo" },
          keys = { { "<leader>/", false } }, -- # this does not work
        },
      },
    },
    notifier = { enabled = true },
    quickfile = { enabled = true },
    scope = { enabled = true },
    scroll = { enabled = false },
    statuscolumn = { enabled = true },
    words = { enabled = true },
  },
  keys = {
    {
      "<leader>t",
      function()
        Snacks.picker.grep()
      end,
      desc = "Grep (Root Dir)",
    }, -- # remapped grep to <leader>t
    {
      "<leader>/",
      false,
    }, -- # removes it from which-key menu
  },
}
