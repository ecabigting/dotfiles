return {
  {
    "saghen/blink.cmp",
    opts = {
      completion = {
        ghost_text = {
          enabled = false,
        },
      },
      enabled = function()
        return not vim.tbl_contains({ "markdown" }, vim.bo.filetype)
      end,
      sources = {
        default = function()
          return { "lsp", "path", "snippets" }
        end,
      },
    },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      inlay_hints = { enabled = false },
    },
  },
  {
    "folke/trouble.nvim",
    opts = {
      win = {
        wo = {
          wrap = true,
        },
      },
    },
  },
  {
    "christoomey/vim-tmux-navigator",
    lazy = false,
    cmd = {
      "TmuxNavigateLeft",
      "TmuxNavigateDown",
      "TmuxNavigateUp",
      "TmuxNavigateRight",
      "TmuxNavigatePrevious",
      "TmuxNavigatorProcessList",
    },
    keys = {
      { "<c-h>", "<cmd><C-U>TmuxNavigateLeft<cr>" },
      { "<c-j>", "<cmd><C-U>TmuxNavigateDown<cr>" },
      { "<c-k>", "<cmd><C-U>TmuxNavigateUp<cr>" },
      { "<c-l>", "<cmd><C-U>TmuxNavigateRight<cr>" },
      { "<c-\\>", "<cmd><C-U>TmuxNavigatePrevious<cr>" },
    },
  },
}
