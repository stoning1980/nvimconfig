-- Treesitter-based document symbols for the current buffer.
-- Useful when an LSP server can't/won't attach (e.g. kotlin_language_server
-- on huge Android/Gradle projects). Parses only the open buffer, so it's
-- instant regardless of project size.

local M = {}

-- Per-language Treesitter queries. The "container" capture name doubles as the
-- LSP SymbolKind (so the Snacks `lsp_symbol` formatter renders the right icon),
-- and the `@name` capture provides the symbol's display name + jump position.
M.queries = {
  -- Only direct members of a class/object/interface body (class_body), so
  -- top-level functions and locals inside method bodies are excluded.
  kotlin = [[
    (class_body (function_declaration (simple_identifier) @name) @Method)
    (class_body (property_declaration (variable_declaration (simple_identifier) @name)) @Property)
  ]],
}

---@param buf? integer
---@return table[]|nil items
function M.get_items(buf)
  buf = buf or 0
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local ft = vim.bo[buf].filetype
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local qstr = M.queries[lang]
  if not qstr then
    return nil
  end

  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang)
  if not ok or not parser then
    return nil
  end

  local ok_q, query = pcall(vim.treesitter.query.parse, lang, qstr)
  if not ok_q then
    return nil
  end

  local root = parser:parse()[1]:root()
  local file = vim.api.nvim_buf_get_name(buf)
  local items = {}

  for _, match in query:iter_matches(root, buf, 0, -1, { all = true }) do
    local kind, name_node
    for id, nodes in pairs(match) do
      local cap = query.captures[id]
      local node = type(nodes) == "table" and nodes[1] or nodes
      if cap == "name" then
        name_node = node
      else
        kind = cap
      end
    end
    if name_node and kind then
      local srow, scol = name_node:range()
      items[#items + 1] = {
        text = kind .. " " .. vim.treesitter.get_node_text(name_node, buf),
        name = vim.treesitter.get_node_text(name_node, buf),
        kind = kind,
        file = file,
        buf = buf,
        pos = { srow + 1, scol },
      }
    end
  end

  table.sort(items, function(a, b)
    if a.pos[1] == b.pos[1] then
      return a.pos[2] < b.pos[2]
    end
    return a.pos[1] < b.pos[1]
  end)
  return items
end

-- Open a Snacks picker with the current file's symbols.
-- Prefers a real LSP (richer symbols) when one is attached and supports
-- documentSymbol; otherwise falls back to the Treesitter extractor.
function M.pick()
  local clients = vim.lsp.get_clients({ bufnr = 0, method = "textDocument/documentSymbol" })
  if #clients > 0 then
    return Snacks.picker.lsp_symbols()
  end

  local items = M.get_items(0)
  if items and #items > 0 then
    return Snacks.picker.pick({
      source = "ts_symbols",
      items = items,
      format = "lsp_symbol",
      title = "Symbols (Treesitter)",
    })
  end

  -- No Treesitter support either: let the LSP picker show its own message.
  return Snacks.picker.lsp_symbols()
end

return M
