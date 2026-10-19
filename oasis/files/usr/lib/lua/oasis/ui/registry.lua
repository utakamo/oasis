-- Package-owned UI handlers. Tool responses select an ID, never a Lua path.
local jsonc = require("luci.jsonc")
local fs = require("nixio.fs")
local M = {}
local directory = "/usr/share/oasis/ui-action.d"

local function trusted(path, kind)
    local stat = fs.lstat(path)
    local mode = stat and stat.modestr
    return stat and stat.type == kind and stat.uid == 0 and type(mode) == "string"
        and mode:sub(5, 5) ~= "w" and mode:sub(8, 8) ~= "w"
end

local function valid_id(value)
    return type(value) == "string" and #value > 0 and #value <= 64
        and value:match("^[A-Za-z_][A-Za-z0-9_.-]*$") ~= nil
end

function M.load()
    if not fs.lstat(directory) then return {} end
    for _, path in ipairs({ "/usr", "/usr/share", "/usr/share/oasis", directory }) do
        if not trusted(path, "dir") then return nil, "Unsafe UI handler directory." end
    end
    local result, count = {}, 0
    local files = fs.dir(directory)
    if not files then return nil, "UI handler directory could not be read." end
    for name in files do
        if name:match("^[A-Za-z0-9_.-]+%.json$") then
            count = count + 1
            local path = directory .. "/" .. name
            local stat = fs.lstat(path)
            if count > 128 or not trusted(path, "reg") or not stat.size or stat.size > 32768 then
                return nil, "Unsafe or oversized UI handler registration."
            end
            local ok, entry = pcall(jsonc.parse, fs.readfile(path) or "")
            if not ok or type(entry) ~= "table" or entry.version ~= 1
                or not valid_id(entry.type) or result[entry.type]
                or type(entry.handler) ~= "string" or #entry.handler > 192
                or not entry.handler:match("^oasis%.[A-Za-z_][A-Za-z0-9_.]*$")
                or entry.handler:find("..", 1, true) or entry.handler:sub(-1) == "."
                or type(entry.bindings) ~= "table" or #entry.bindings == 0
                or #entry.bindings > 64 then
                return nil, "Invalid or duplicate UI handler registration."
            end
            local bindings = 0
            for key, binding in pairs(entry.bindings) do
                bindings = bindings + 1
                if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #entry.bindings
                    or type(binding) ~= "table" or not valid_id(binding.server)
                    or not valid_id(binding.method) or not valid_id(binding.operation) then
                    return nil, "Invalid UI handler binding."
                end
            end
            if bindings ~= #entry.bindings then return nil, "Invalid UI handler bindings." end
            result[entry.type] = entry
        end
    end
    return result
end

function M.resolve(entries, action, source)
    if type(action) ~= "table" or not valid_id(action.type) then return nil, "Invalid UI action." end
    local entry = entries[action.type]
    if not entry then return nil, "Unsupported UI action type." end
    if action.version ~= 1 and not (action.version == nil and entry.accept_legacy == true) then
        return nil, "Unsupported UI action version."
    end
    if action.fields ~= nil and entry.allow_fields ~= true then return nil, "Inline fields are not supported by this handler." end
    local matched = false
    for _, binding in ipairs(entry.bindings) do
        if binding.server == source.server and binding.method == source.method
            and binding.operation == action.operation then matched = true end
    end
    if not matched then return nil, "UI action does not match the executed tool." end
    local ok, handler = pcall(require, entry.handler)
    if not ok or type(handler) ~= "table" or type(handler.prepare) ~= "function"
        or type(handler.advance) ~= "function" or type(handler.apply) ~= "function" then
        return nil, "UI handler is unavailable or incompatible."
    end
    return handler
end

return M
