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

-- Table
M.table = function(tbl)
  if #tbl == 0 then return "" end

  local col_count = #tbl[1]

  local header = "| " .. table.concat(tbl[1], " | ") .. " |"

  local sep_parts = {}
  for _ = 1, col_count do
    table.insert(sep_parts, "----")
  end
  local separator = "| " .. table.concat(sep_parts, " | ") .. " |"

  local rows = {}
  for i = 2, #tbl do
    local row = {}
    for j = 1, col_count do
      row[j] = tbl[i][j] or ""
    end
    table.insert(rows, "| " .. table.concat(row, " | ") .. " |")
  end

  return table.concat({ header, separator, table.concat(rows, "\n") }, "\n")
end

return M