local fs = require("nixio.fs")
local guard = require("oasis.security.guard")

local M = {}

local TEMPLATE_PATHS = {
    lua = "/etc/oasis/tool-maker/lua/template",
    ucode = "/etc/oasis/tool-maker/ucode/template",
}

local function locate_body_bounds(template)
    local start_marker = "OASIS_TOOL_INSERT_BEGIN"
    local end_marker = "OASIS_TOOL_INSERT_END"

    local start_pos = template:find(start_marker, 1, true)
    if not start_pos then
        return nil, "marker begin not found"
    end

    local start_line_end = template:find("\n", start_pos)
    if not start_line_end then
        return nil, "marker begin line not found"
    end

    local end_pos = template:find(end_marker, start_line_end + 1, true)
    if not end_pos then
        return nil, "marker end not found"
    end

    local end_line_start = template:sub(1, end_pos):match(".*()\n")
    if not end_line_start then
        return nil, "marker end line not found"
    end

    return start_line_end, end_line_start
end

local function inject_body(template, body)
    local start_line_end, end_line_start = locate_body_bounds(template)
    if not start_line_end then
        return nil, end_line_start
    end

    local prefix = template:sub(1, start_line_end)
    local suffix = template:sub(end_line_start + 1)
    local insert = body or ""

    if #insert > 0 and insert:sub(-1) ~= "\n" then
        insert = insert .. "\n"
    end

    return prefix .. insert .. suffix
end

local function read_template(tool_type)
    if tool_type ~= "lua" and tool_type ~= "ucode" then
        return nil, "invalid template type"
    end

    local path = TEMPLATE_PATHS[tool_type]
    local content = fs.readfile(path)
    if not content then
        return nil, "template not found"
    end

    return content
end

local function build_tool_calls(tool_type, tools, group)
    if type(tools) ~= "table" then
        return nil, "invalid tools"
    end

    local function quote(s)
        s = tostring(s or "")
        s = s:gsub("\\", "\\\\"):gsub("\"", "\\\"")
        return "\"" .. s .. "\""
    end

    local function indent_lines(text, pad)
        local prefix = string.rep(" ", pad or 0)
        local out = {}
        local lines = tostring(text or "")
        if lines == "" then
            return prefix
        end
        for line in lines:gmatch("([^\n]*)\n?") do
            out[#out + 1] = prefix .. line
        end
        -- Remove possible trailing empty line from gmatch
        if #out > 0 and out[#out] == prefix then
            out[#out] = nil
        end
        return table.concat(out, "\n")
    end

    local buf = {}
    for _, tool in ipairs(tools) do
        local name = tool.name or ""
        local tool_desc = tool.tool_desc or ""
        local args = tool.args or {}
        local args_desc = tool.args_desc or {}
        local call_body = tool.call_body or ""

        if name == "" then
            return nil, "missing tool name"
        end
        if tool_desc == "" then
            return nil, "missing tool description"
        end
        if call_body == "" then
            return nil, "missing call body"
        end
        if type(args) ~= "table" or type(args_desc) ~= "table" then
            return nil, "invalid args"
        end
        if #args ~= #args_desc then
            return nil, "args and args_desc mismatch"
        end

        name = guard.sanitize(name)

        local args_desc_lines = {}
        for _, desc in ipairs(args_desc) do
            args_desc_lines[#args_desc_lines + 1] = quote(desc)
        end

        local args_lines = {}
        for _, arg in ipairs(args) do
            local aname = guard.sanitize(arg.name or "")
            local atype = arg.type or ""
            if aname == "" or atype == "" then
                return nil, "invalid arg"
            end
            if tool_type == "lua" then
                args_lines[#args_lines + 1] = string.format("%s = %s", aname, quote(atype))
            else
                args_lines[#args_lines + 1] = string.format("%s: %s", aname, quote(atype))
            end
        end

        if tool_type == "lua" then
            local def = {
                "server.tool(" .. quote(name) .. ", {",
                "    tool_desc = " .. quote(tool_desc) .. ",",
                "    args_desc = { " .. table.concat(args_desc_lines, ", ") .. " },",
                "    args = { " .. table.concat(args_lines, ", ") .. " },",
                "    call = function(args)",
                indent_lines(call_body, 8),
                "    end",
                "})"
            }
            buf[#buf + 1] = table.concat(def, "\n")
        else
            local grp = group or "oasis.ucode.tool"
            grp = guard.sanitize(grp)
            local def = {
                "server.tool(" .. quote(grp) .. ", " .. quote(name) .. ", {",
                "    tool_desc: " .. quote(tool_desc) .. ",",
                "    args_desc: [ " .. table.concat(args_desc_lines, ", ") .. " ],",
                "    args: { " .. table.concat(args_lines, ", ") .. " },",
                "    call: function(request) {",
                indent_lines(call_body, 8),
                "    }",
                "});"
            }
            buf[#buf + 1] = table.concat(def, "\n")
        end
    end

    return table.concat(buf, "\n\n")
end

function M.list_templates()
    return {
        { id = "lua", label = "Lua", type = "lua" },
        { id = "ucode", label = "uCode", type = "ucode" },
    }
end

function M.get_template(tool_type)
    local template, err = read_template(tool_type)
    if not template then
        return nil, nil, err
    end

    return template, nil, nil
end

function M.render(tool_type, tools, group)
    local template, err = read_template(tool_type)
    if not template then
        return nil, err
    end

    local body, build_err = build_tool_calls(tool_type, tools, group)
    if not body then
        return nil, build_err
    end

    local content, render_err = inject_body(template, body)
    if not content then
        return nil, render_err
    end

    return content, nil
end

function M.validate(tool_type, tools, group)
    local template, err = read_template(tool_type)
    if not template then
        return false, { err or "template not found" }
    end

    local start_line_end, end_line_start = locate_body_bounds(template)
    if not start_line_end then
        local marker_err = end_line_start
        return false, { marker_err }
    end

    if type(tools) ~= "table" or #tools == 0 then
        return false, { "empty tools" }
    end

    for _, tool in ipairs(tools) do
        if not tool.tool_desc or tool.tool_desc == "" then
            return false, { "missing tool description" }
        end
    end

    local body, build_err = build_tool_calls(tool_type, tools, group)
    if not body then
        return false, { build_err or "failed to build tools" }
    end

    local content, render_err = inject_body(template, body)
    if not content then
        return false, { render_err or "failed to render" }
    end

    if tool_type == "lua" then
        local stripped = content:gsub("^#![^\n]*\n", "")
        local loader = load or loadstring
        local fn, syntax_err = loader(stripped, "oasis-tool")
        if not fn then
            return false, { syntax_err or "lua syntax error" }
        end
    elseif tool_type == "ucode" then
        if fs.stat("/usr/bin/ucode") then
            local tmp = string.format("/tmp/oasis_tool_maker_validate_%d_%d", os.time(), math.random(1000, 9999))
            local ok = fs.writefile(tmp, content)
            if not ok then
                return false, { "failed to write temp file" }
            end
            local rc = os.execute("ucode " .. tmp .. " >/dev/null 2>&1")
            fs.remove(tmp)
            if rc ~= true and rc ~= 0 then
                return false, { "ucode syntax error" }
            end
        end
    end

    return true, {}
end

function M.save(tool_type, name, content)
    if tool_type ~= "lua" and tool_type ~= "ucode" then
        return false, "invalid tool type"
    end

    if not name or name == "" then
        return false, "missing name"
    end

    if not guard.check_safe_string(name) then
        return false, "invalid name"
    end

    if not content or #content == 0 then
        return false, "empty content"
    end

    local safe_name = guard.sanitize(name)
    local target_dir = (tool_type == "lua") and "/usr/libexec/rpcd/" or "/usr/share/rpcd/ucode/"
    local target_path = target_dir .. safe_name

    if fs.stat(target_path) then
        return false, "already exists"
    end

    local ok = fs.writefile(target_path, content)
    if not ok then
        return false, "failed to write file"
    end

    if tool_type == "lua" then
        local mode = tonumber("755", 8)
        local chmod_ok = fs.chmod(target_path, mode)
        if not chmod_ok then
            return false, "failed to chmod"
        end
    end

    return true, { path = target_path, bytes = #content }
end

return M
