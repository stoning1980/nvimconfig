-- render-markdown draws fenced code blocks as a full-width extmark background,
-- and extmark backgrounds always paint over CursorLine regardless of their
-- priority -- so the cursor line vanishes inside every code block. Drop the
-- tint; the sign column marker and language label still delimit the block.
return {
  "MeanderingProgrammer/render-markdown.nvim",
  opts = {
    code = { disable_background = true },
  },
}
