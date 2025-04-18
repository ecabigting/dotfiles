return {
  {
    "neovim/nvim-lspconfig",
    event = "LazyFile",
    dependencies = {
      "mason.nvim",
      { "williamboman/mason-lspconfig.nvim", config = function() end },
    },
    opts = {
      inlay_hints = {
        enabled = false,
        exclude = { "vue" }, -- filetypes for which you don't want to enable inlay hints
      },
      servers = {
        eslint = {
          -- settings = {
          --   useFlatConfig = false,
          --   workingDirectories = { mode = "auto" },
          --   experimental = {
          --     useFlatConfig = false,
          --   },
          -- },
        },
      },
    },
  },
}
