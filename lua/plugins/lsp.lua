return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      -- kotlin_language_server can't handle large Android/Gradle monorepos:
      -- it tries to resolve the whole classpath and index every file on
      -- initialize, then hangs/crashes (0 clients attach) while spinning up a
      -- heavy JVM. Disabled here; current-file symbols come from the
      -- Treesitter-based picker (<F8>, see lua/config/ts_symbols.lua) instead.
      kotlin_language_server = { enabled = false },
    },
  },
}
