
-- Validate UTF-8 and detect suspicious code points (BOM, BIDI, zero-width, combining marks, etc.)
local detect_encoding_spoof = function(s)
    if type(s) ~= "string" then return true, "not-string" end

    local i = 1
    local n = #s

    while i <= n do
        local c = s:byte(i)

        -- ASCII
        if c < 0x80 then
            -- Control characters (add allowed characters here if needed)
            if c < 0x20 or c == 0x7F then
                return true, "control-char"
            end
            i = i + 1

    -- 2-byte sequence
        elseif c >= 0xC2 and c <= 0xDF then
            if i + 1 > n then return true, "invalid-utf8" end
            local b1 = s:byte(i+1)
            if b1 < 0x80 or b1 > 0xBF then return true, "invalid-utf8" end

            local cp = (c - 0xC0) * 64 + (b1 - 0x80)

            if (cp >= 0x0300 and cp <= 0x036F) or cp == 0x200B or cp == 0xFEFF then
                return true, string.format("suspicious-cp:U+%X", cp)
            end

            i = i + 2

    -- 3-byte sequence
        elseif c >= 0xE0 and c <= 0xEF then
            if i + 2 > n then return true, "invalid-utf8" end
            local b1 = s:byte(i+1); local b2 = s:byte(i+2)
            if b1 < 0x80 or b1 > 0xBF or b2 < 0x80 or b2 > 0xBF then return true, "invalid-utf8" end

            local cp = (c - 0xE0) * 4096 + (b1 - 0x80) * 64 + (b2 - 0x80)

            if (cp >= 0x202A and cp <= 0x202E)        -- BIDI controls (RLO/LRO etc.)
               or (cp >= 0x2066 and cp <= 0x2069)    -- isolate controls
               or (cp >= 0x200B and cp <= 0x200F)    -- zero-width / marks
               or (cp >= 0x0300 and cp <= 0x036F)    -- combining diacritics
               or (cp >= 0xFE00 and cp <= 0xFE0F)    -- variation selectors
               or cp == 0xFEFF then                   -- BOM
                return true, string.format("suspicious-cp:U+%X", cp)
            end

            i = i + 3

    -- 4-byte sequence
        elseif c >= 0xF0 and c <= 0xF4 then
            if i + 3 > n then return true, "invalid-utf8" end
            local b1 = s:byte(i+1); local b2 = s:byte(i+2); local b3 = s:byte(i+3)
            if b1 < 0x80 or b1 > 0xBF or b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then
                return true, "invalid-utf8"
            end

            local cp = (c - 0xF0) * 262144 + (b1 - 0x80) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)

            -- Additional checks can be added here if necessary
            if (cp >= 0x1F000 and cp <= 0x1FFFF) then
                return true, string.format("suspicious-cp:U+%X", cp)
            end

            i = i + 4

        else
            return true, "invalid-utf8"
        end
    end

    -- NOTE: rejecting all non-ASCII bytes is often too strict for real-world use.
    -- If you want to keep the strict behaviour, uncomment the block below.
    -- Treat presence of non-ASCII bytes as potential encoding spoofing
    -- for j = 1, #s do
    --     if s:byte(j) > 127 then
    --         return true, "non-ascii"
    --     end
    -- end

    return false, nil
end

local sanitize = function(str)
  return str:gsub("[;&|><`]", "")
end

local is_safe_input = function(str)
  return str:match("^[%w%-_%.]+$") ~= nil
end

-- String safety check (includes encoding spoof detection)
local check_safe_string = function(str)

    if type(str) ~= "string" then
        return false
    end

    -- if not is_safe_input(str) then
    --     return false
    -- end

    pkg = pkg:match("^%s*(.-)%s*$") or ""

    -- Check for encoding spoofing (non-ASCII/invalid UTF-8/BIDI/zero-width/combining marks etc.)
    local spoofed, reason = detect_encoding_spoof(str)
    if spoofed then
        return false
    end

    -- Allowed characters: alphanumerics, underscore, dot, @, :, +, =, - only
    if pkg:match("^[%w._@:+=-]+$") then
        return true
    end

    return false
end

return {
    sanitize = sanitize,
    check_safe_string = check_safe_string,
}
