#!/usr/bin/env lua

local M = {}

-- Heading
M.h1 = function(text)
    return string.format("# %s", text)
end

M.h2 = function(text)
    return string.format("## %s", text)
end

M.h3 = function(text)
    return string.format("### %s", text)
end

M.h4 = function(text)
    return string.format("### %s", text)
end

M.h5 = function(text)
    return string.format("#### %s", text)
end

M.h6 = function(text)
    return string.format("##### %s", text)
end

-- Bold
M.bold = function(text)
    return string.format("**%s**", text)
end

-- Italic
M.italic = function(text)
    return string.format("*%s*", text)
end

-- Inline code
M.code = function(text)
    return string.format("`%s`", text)
end

-- Code block
M.codeblock = function(text)
    return string.format("```\n%s\n```\n", text)
end

-- Unordered list (ulist)
M.ulist = function(items)
    local lines = {}
    for _, item in ipairs(items) do
        table.insert(lines, "- " .. item)
    end
    return table.concat(lines, "\n")
end

-- Ordered list (olist)
M.olist = function(items)
    local lines = {}
    for i, item in ipairs(items) do
        table.insert(lines, string.format("%d. %s", i, item))
    end
    return table.concat(lines, "\n")
end

-- Blockquote
M.blockquote = function(text)
    return string.format("> %s", text)
end

-- Link
M.link = function(text, url)
    return string.format("[%s](%s)", text, url)
end

-- Image
M.image = function(alt, url)
    return string.format("![%s](%s)", alt, url)
end

-- Table (aligned markdown table)
M.table = function(tbl)
  -- Return empty string if table is empty
  if #tbl == 0 then return "" end

  -- Determine the maximum number of columns
  local max_cols = 0
  for _, row in ipairs(tbl) do
    if #row > max_cols then
      max_cols = #row
    end
  end

  -- Pad rows with empty strings if they have fewer columns
  for _, row in ipairs(tbl) do
    while #row < max_cols do
      table.insert(row, "")
    end
  end

  -- Calculate column widths based on the maximum cell length per column
  local col_widths = {}
  for c = 1, max_cols do
    local w = 0
    for r = 1, #tbl do
      local cell = tostring(tbl[r][c] or "")
      local len = #cell
      if len > w then w = len end
    end
    -- Ensure a minimum width of 1 for readability
    if w < 1 then w = 1 end
    col_widths[c] = w
  end

  -- Right-pad a string with spaces to match the given width
  local function pad_right(s, width)
    s = tostring(s or "")
    local len = #s
    if len >= width then return s end
    return s .. string.rep(" ", width - len)
  end

  -- Render a single table row
  local function render_row(row)
    local parts = {}
    for c = 1, max_cols do
      parts[c] = pad_right(row[c], col_widths[c])
    end
    return "| " .. table.concat(parts, " | ") .. " |"
  end

  -- Render the separator row between header and body
  local function render_separator()
    local parts = {}
    for c = 1, max_cols do
      -- Use at least 3 dashes per column
      parts[c] = string.rep("-", math.max(3, col_widths[c]))
    end
    return "| " .. table.concat(parts, " | ") .. " |"
  end

  -- Assemble the final output
  local out = {}

  -- Header row
  table.insert(out, render_row(tbl[1]))
  table.insert(out, render_separator())

  -- Data rows
  for i = 2, #tbl do
    table.insert(out, render_row(tbl[i]))
  end

  return table.concat(out, "\n")
end

return M
