return {
  {
    "neovim/nvim-lspconfig",
    event = "LazyFile",
    dependencies = {
      "mason.nvim",
      { "williamboman/mason-lspconfig.nvim", config = function() end },
    },
    opts = {
      servers = {
        ts_ls = {
          completeUnimported = true,
        },
        tailwindcss = {},
        gopls = {
          completeUnimported = true,
        },
        eslint = {
          settings = {
            workingDirectories = { mode = "auto" },
          },
        },
        rust_analyzer = {
          completeUnimported = true,
        },
      },
    },
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = {
      ensure_installed = {
        "go",
        "goctl",
      },
    },
  },
}
