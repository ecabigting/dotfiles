return {
  "saghen/blink.cmp",
  opts = {
    sources = {
      -- adding any nvim-cmp sources here will enable them
      -- with blink.compat
      compat = { name = "buffer", keyword_length = 9999 },
      default = { "lsp", "path", "snippets" },
    },
  },
}
