local i18n = require("luci.i18n")
local jsonc = require("luci.jsonc")

local M = {}

-- Return a JavaScript string literal, not HTML-escaped text. Escaping '<'
-- also prevents a translated </script> from closing an inline script element.
function M.translate_js(message)
    local encoded = jsonc.stringify(i18n.translate(message))
    encoded = encoded:gsub("<", "\\u003c"):gsub(">", "\\u003e"):gsub("&", "\\u0026")
    encoded = encoded:gsub("\226\128\168", "\\u2028"):gsub("\226\128\169", "\\u2029")
    return encoded
end

return M
