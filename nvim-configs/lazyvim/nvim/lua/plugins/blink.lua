return {
  {
    "saghen/blink.cmp",
    opts = {
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
}
