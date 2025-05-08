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
}
