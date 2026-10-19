-- Declarative CLI forms. No tool-specific logic or executable expressions.
local M = {}
local types = { string = true, secret = true, integer = true, number = true,
    boolean = true, select = true, multiselect = true }

function M.text(value)
    return tostring(value or ""):gsub("[%z\1-\31\127]", " ")
end

local function styled(terminal, style, value)
    local text = M.text(value)
    return terminal.form_style and terminal.form_style(style, text) or text
end

local function heading(terminal, title)
    terminal.print("\n  " .. styled(terminal, "heading", title))
    terminal.print("  " .. styled(terminal, "hint", string.rep("-", 40)))
end

function M.status(terminal, status, message)
    local style = status == "applied" and "success" or (status == "failed" and "error" or "warning")
    terminal.print("\n" .. styled(terminal, style, "[ui_action:" .. status .. "]") .. " " .. M.text(message) .. "\n")
end

function M.validation_error(terminal, message)
    terminal.print("    " .. styled(terminal, "error", "! " .. message))
end

function M.review(sections, terminal)
    heading(terminal, "Review changes")
    for _, section in ipairs(sections) do
        terminal.print("\n  " .. styled(terminal, "label", section.title))
        for _, line in ipairs(section.lines) do terminal.print("    " .. M.text(line)) end
    end
end

local function array(value, maximum)
    if type(value) ~= "table" then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
    end
    return count == #value and count <= maximum
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function validate_value(field, value)
    if value == nil or (value == "" and (field.type == "string" or field.type == "secret")) then
        if field.required then return false, "A value is required." end
        return true
    end
    local kind = field.type
    if kind == "string" or kind == "secret" then
        if type(value) ~= "string" or value:find("[%z\1-\31\127]")
            or #value < (field.min_length or 0) or #value > (field.max_length or 4096) then
            return false, "Invalid text length or control character."
        end
    elseif kind == "integer" or kind == "number" then
        if not finite(value) or (kind == "integer" and value % 1 ~= 0)
            or (field.min ~= nil and value < field.min)
            or (field.max ~= nil and value > field.max) then
            return false, "Enter a number within the allowed range."
        end
    elseif kind == "boolean" then
        if type(value) ~= "boolean" then return false, "Enter y or n." end
    else
        local values = kind == "select" and { value } or value
        if not array(values, 128) or (field.required and #values == 0) then
            return false, "Select one or more listed choices."
        end
        local seen = {}
        for _, selected in ipairs(values) do
            local found = false
            for _, option in ipairs(field.choices) do
                if option.value == selected then found = true end
            end
            if not found or seen[selected] then return false, "Select distinct listed choices." end
            seen[selected] = true
        end
    end
    return true
end

function M.validate(definition)
    if type(definition) ~= "table" or type(definition.title) ~= "string"
        or #definition.title > 256 or not array(definition.fields, 64) then
        return nil, "Invalid form definition."
    end
    for key in pairs(definition) do
        if key ~= "title" and key ~= "fields" then return nil, "Unsupported form attribute." end
    end
    local names = {}
    local allowed = { name = true, label = true, type = true, required = true,
        default = true, choices = true, min = true, max = true,
        min_length = true, max_length = true, help = true }
    for _, field in ipairs(definition.fields) do
        if type(field) ~= "table" or type(field.name) ~= "string"
            or #field.name > 64 or not field.name:match("^[A-Za-z_][A-Za-z0-9_]*$")
            or names[field.name] or not types[field.type]
            or type(field.label) ~= "string" or #field.label > 256
            or (field.required ~= nil and type(field.required) ~= "boolean")
            or (field.help ~= nil and (type(field.help) ~= "string" or #field.help > 1024)) then
            return nil, "Invalid or duplicate form field."
        end
        names[field.name] = true
        for key in pairs(field) do
            if not allowed[key] then return nil, "Unsupported field attribute." end
        end
        for _, key in ipairs({ "min", "max", "min_length", "max_length" }) do
            if field[key] ~= nil and not finite(field[key]) then return nil, "Invalid field limit." end
        end
        if (field.min and field.max and field.min > field.max)
            or (field.min_length and (field.min_length < 0 or field.min_length % 1 ~= 0))
            or (field.max_length and (field.max_length < 0 or field.max_length > 4096 or field.max_length % 1 ~= 0))
            or ((field.min_length or 0) > (field.max_length or 4096)) then
            return nil, "Invalid field range."
        end
        if field.type == "select" or field.type == "multiselect" then
            if not array(field.choices, 128) or #field.choices == 0 then return nil, "Missing choices." end
            local seen = {}
            for _, choice in ipairs(field.choices) do
                if type(choice) ~= "table" or type(choice.value) ~= "string"
                    or #choice.value == 0 or #choice.value > 256 or seen[choice.value]
                    or type(choice.label) ~= "string" or #choice.label > 256 then
                    return nil, "Invalid or duplicate choice."
                end
                seen[choice.value] = true
            end
        elseif field.choices ~= nil then return nil, "Choices require a selection field." end
        if field.type == "secret" and field.default ~= nil then return nil, "Secret defaults are forbidden." end
        if field.default ~= nil then
            local ok = validate_value(field, field.default)
            if not ok then return nil, "Invalid default value." end
        end
    end
    return true
end

local function display_value(field, value)
    if field.type == "secret" then return "[hidden]" end
    if field.type == "select" or field.type == "multiselect" then
        local labels = {}
        local selected = field.type == "select" and { value } or (value or {})
        for _, item in ipairs(selected) do
            for _, choice in ipairs(field.choices) do
                if item == choice.value then labels[#labels + 1] = M.text(choice.label) end
            end
        end
        return table.concat(labels, ", ")
    end
    if value == nil then return "(empty)" end
    return M.text(tostring(value))
end

function M.read(definition, terminal)
    local valid, err = M.validate(definition)
    if not valid then return nil, err end
    heading(terminal, definition.title)
    terminal.print("  " .. styled(terminal, "hint", "Type /cancel at any prompt to cancel."))
    local values, summary = {}, {}
    for _, field in ipairs(definition.fields) do
        terminal.print("\n  " .. styled(terminal, "label", field.label)
            .. styled(terminal, "hint", field.required and " (required)" or " (optional)"))
        if field.help then terminal.print("    " .. styled(terminal, "hint", field.help)) end
        if field.choices then
            for index, choice in ipairs(field.choices) do
                terminal.print("    " .. styled(terminal, "heading", string.format("%3d.", index)) .. " " .. M.text(choice.label))
            end
        end
        if field.default ~= nil then
            terminal.print("    " .. styled(terminal, "hint", "Default: " .. display_value(field, field.default) .. " (Enter to keep)"))
        end
        if field.type == "boolean" then
            terminal.print("    " .. styled(terminal, "hint", "Enter y or n."))
        elseif field.type == "multiselect" then
            terminal.print("    " .. styled(terminal, "hint", "Select numbers separated by commas."))
        elseif field.type == "select" then
            terminal.print("    " .. styled(terminal, "hint", "Select a number."))
        end
        while true do
            terminal.write("    " .. styled(terminal, "heading", ">") .. " ")
            terminal.flush()
            local raw, read_error
            if field.type == "secret" then raw, read_error = terminal.read_secret()
            else raw, read_error = terminal.read_form_line() end
            if raw == "/cancel" or (raw == nil and read_error ~= "input_too_long") then
                return nil, "cancelled"
            end
            local value = raw
            if raw == "" and field.default ~= nil then value = field.default
            elseif raw ~= nil and raw ~= "" then
                if field.type == "integer" or field.type == "number" then
                    value = tonumber(raw)
                elseif field.type == "boolean" then
                    local lower = raw:lower()
                    if lower == "y" or lower == "yes" then value = true
                    elseif lower == "n" or lower == "no" then value = false end
                elseif field.type == "select" then
                    local index = tonumber(raw)
                    local choice = index and field.choices[index]
                    value = choice and choice.value or raw
                    if not choice then value = nil end
                elseif field.type == "multiselect" then
                    value = {}
                    if not raw:match("^%s*%d[%d,%s]*$") or raw:match(",%s*,") or raw:match(",%s*$") then
                        value = nil
                    else
                        for part in raw:gmatch("[^,]+") do
                            local index = tonumber(part)
                            local choice = index and field.choices[index]
                            if not choice then value = nil; break end
                            value[#value + 1] = choice.value
                        end
                    end
                end
            elseif field.type == "multiselect" then value = {}
            elseif field.type ~= "string" and field.type ~= "secret" then value = nil end
            local ok, message = validate_value(field, value)
            if raw == nil or (raw ~= "" and value == nil) then ok, message = false, "Invalid input." end
            if ok then
                values[field.name] = value
                summary[#summary + 1] = M.text(field.label) .. ": " .. display_value(field, value)
                break
            end
            M.validation_error(terminal, message)
        end
    end
    return values, summary
end

function M.confirm(terminal)
    terminal.print("\n  " .. styled(terminal, "hint", "Enter y to apply; Enter or n to cancel."))
    terminal.write("  " .. styled(terminal, "warning", "Apply these changes? [y/N]") .. " > ")
    terminal.flush()
    local value = terminal.read_form_line()
    return value ~= nil and (value:lower() == "y" or value:lower() == "yes")
end

return M
