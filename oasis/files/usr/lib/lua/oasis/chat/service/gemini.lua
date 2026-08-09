#!/usr/bin/env lua

local jsonc           = require("luci.jsonc")
local common          = require("oasis.common")
local util            = require("luci.util")
local datactrl        = require("oasis.chat.datactrl")
local misc            = require("oasis.chat.misc")
local debug           = require("oasis.chat.debug")
local ous             = require("oasis.unified.chat.schema")
local calling         = require("oasis.chat.function.calling.gemini")
local chat_error      = require("oasis.chat.error")
local response_framer = require("oasis.chat.response_framer")

local MAX_RESPONSE_BYTES = 4 * 1024 * 1024
local MAX_STREAM_RECORDS = 65536
local MAX_RESPONSE_PARTS = 8192
local MAX_JSON_DEPTH = 128
local MAX_JSON_VALUES = 131072
local MAX_PENDING_TOOL_BYTES = 8 * 1024 * 1024
local MAX_PENDING_TOOL_CONTENTS = 256
local MAX_TOOL_CALL_ID_BYTES = 1024

local function skip_json_whitespace(text, position)
    local length = #text
    while position <= length do
        local byte = text:byte(position)
        if byte ~= 0x20 and byte ~= 0x09
            and byte ~= 0x0a and byte ~= 0x0d then
            break
        end
        position = position + 1
    end
    return position
end

local function scan_json_string(text, position)
    if text:sub(position, position) ~= '"' then
        return nil, "expected a JSON string"
    end

    local length = #text
    local cursor = position + 1
    while cursor <= length do
        local byte = text:byte(cursor)
        if byte == 0x22 then
            return cursor, nil
        elseif byte == 0x5c then
            local escape = text:sub(cursor + 1, cursor + 1)
            if escape == "u" then
                local hex = text:sub(cursor + 2, cursor + 5)
                if #hex ~= 4 or not hex:match("^%x%x%x%x$") then
                    return nil, "invalid JSON unicode escape"
                end
                cursor = cursor + 6
            elseif escape == '"' or escape == "\\"
                or escape == "/" or escape == "b" or escape == "f"
                or escape == "n" or escape == "r" or escape == "t" then
                cursor = cursor + 2
            else
                return nil, "invalid JSON string escape"
            end
        elseif byte < 0x20 then
            return nil, "unescaped control character in JSON string"
        else
            cursor = cursor + 1
        end
    end
    return nil, "unterminated JSON string"
end

local function utf8_from_codepoint(codepoint)
    if codepoint <= 0x7f then
        return string.char(codepoint)
    elseif codepoint <= 0x7ff then
        return string.char(
            0xc0 + math.floor(codepoint / 0x40),
            0x80 + (codepoint % 0x40)
        )
    elseif codepoint <= 0xffff then
        return string.char(
            0xe0 + math.floor(codepoint / 0x1000),
            0x80 + (math.floor(codepoint / 0x40) % 0x40),
            0x80 + (codepoint % 0x40)
        )
    elseif codepoint <= 0x10ffff then
        return string.char(
            0xf0 + math.floor(codepoint / 0x40000),
            0x80 + (math.floor(codepoint / 0x1000) % 0x40),
            0x80 + (math.floor(codepoint / 0x40) % 0x40),
            0x80 + (codepoint % 0x40)
        )
    end
    return nil
end

local JSON_ESCAPES = {
    ['"'] = '"',
    ["\\"] = "\\",
    ["/"] = "/",
    b = "\b",
    f = "\f",
    n = "\n",
    r = "\r",
    t = "\t",
}

local function decode_json_string(text, first, last)
    local pieces = {}
    local cursor = first + 1
    local chunk_start = cursor
    while cursor < last do
        local char = text:sub(cursor, cursor)
        if char ~= "\\" then
            cursor = cursor + 1
        else
            if chunk_start < cursor then
                pieces[#pieces + 1]
                    = text:sub(chunk_start, cursor - 1)
            end
            local escape = text:sub(cursor + 1, cursor + 1)
            if escape ~= "u" then
                local decoded = JSON_ESCAPES[escape]
                if decoded == nil then
                    return nil, "invalid JSON key escape"
                end
                pieces[#pieces + 1] = decoded
                cursor = cursor + 2
                chunk_start = cursor
            else
                local high = tonumber(text:sub(cursor + 2, cursor + 5), 16)
                if not high then
                    return nil, "invalid JSON key unicode escape"
                end
                cursor = cursor + 6
                local codepoint = high
                if high >= 0xd800 and high <= 0xdbff then
                    if text:sub(cursor, cursor + 1) ~= "\\u" then
                        return nil, "unpaired high surrogate in JSON key"
                    end
                    local low = tonumber(
                        text:sub(cursor + 2, cursor + 5), 16)
                    if not low or low < 0xdc00 or low > 0xdfff then
                        return nil, "invalid low surrogate in JSON key"
                    end
                    codepoint = 0x10000
                        + (high - 0xd800) * 0x400
                        + (low - 0xdc00)
                    cursor = cursor + 6
                elseif high >= 0xdc00 and high <= 0xdfff then
                    return nil, "unpaired low surrogate in JSON key"
                end
                local encoded = utf8_from_codepoint(codepoint)
                if not encoded then
                    return nil, "invalid codepoint in JSON key"
                end
                pieces[#pieces + 1] = encoded
                chunk_start = cursor
            end
        end
    end
    if chunk_start < last then
        pieces[#pieces + 1] = text:sub(chunk_start, last - 1)
    end
    return table.concat(pieces), nil
end

local function scan_json_number(text, position)
    local cursor = position
    local length = #text
    if text:sub(cursor, cursor) == "-" then
        cursor = cursor + 1
    end
    local first = text:sub(cursor, cursor)
    if first == "0" then
        cursor = cursor + 1
        if text:sub(cursor, cursor):match("%d") then
            return nil, "leading zero in JSON number"
        end
    elseif first:match("[1-9]") then
        repeat
            cursor = cursor + 1
        until cursor > length
            or not text:sub(cursor, cursor):match("%d")
    else
        return nil, "invalid JSON number"
    end

    if text:sub(cursor, cursor) == "." then
        cursor = cursor + 1
        if not text:sub(cursor, cursor):match("%d") then
            return nil, "invalid JSON number fraction"
        end
        repeat
            cursor = cursor + 1
        until cursor > length
            or not text:sub(cursor, cursor):match("%d")
    end

    local exponent = text:sub(cursor, cursor)
    if exponent == "e" or exponent == "E" then
        cursor = cursor + 1
        local sign = text:sub(cursor, cursor)
        if sign == "+" or sign == "-" then
            cursor = cursor + 1
        end
        if not text:sub(cursor, cursor):match("%d") then
            return nil, "invalid JSON number exponent"
        end
        repeat
            cursor = cursor + 1
        until cursor > length
            or not text:sub(cursor, cursor):match("%d")
    end
    return cursor - 1, nil
end

local REQUIRED_JSON_OBJECT = {
    response = true,
    candidate = true,
    content = true,
    part = true,
    function_call = true,
    function_args = true,
}

local REQUIRED_JSON_ARRAY = {
    response_array = true,
    candidates = true,
    parts = true,
}

local function child_json_state(state, key)
    if state == "response" and key == "candidates" then
        return "candidates"
    elseif state == "candidate" and key == "content" then
        return "content"
    elseif state == "content" and key == "parts" then
        return "parts"
    elseif state == "part" and key == "functionCall" then
        return "function_call"
    elseif state == "function_call" and key == "args" then
        return "function_args"
    end
    return "ignore"
end

local scan_json_value

scan_json_value = function(text, position, depth, state, context)
    if depth > MAX_JSON_DEPTH then
        return nil, nil, "JSON nesting exceeded the depth limit"
    end
    context.value_count = context.value_count + 1
    if context.value_count > MAX_JSON_VALUES then
        return nil, nil, "JSON value count exceeded the limit"
    end

    position = skip_json_whitespace(text, position)
    local char = text:sub(position, position)
    if REQUIRED_JSON_OBJECT[state] and char ~= "{" then
        return nil, nil, state .. " must be a JSON object"
    elseif REQUIRED_JSON_ARRAY[state] and char ~= "[" then
        return nil, nil, state .. " must be a JSON array"
    end

    if char == '"' then
        local last, err = scan_json_string(text, position)
        return last, last and "string" or nil, err
    elseif char == "{" then
        local keys = {}
        local cursor = skip_json_whitespace(text, position + 1)
        if text:sub(cursor, cursor) == "}" then
            return cursor, "object", nil
        end

        while true do
            local key_first = cursor
            local key_last, key_error = scan_json_string(text, key_first)
            if not key_last then
                return nil, nil, key_error
            end
            local key, decode_error =
                decode_json_string(text, key_first, key_last)
            if not key then
                return nil, nil, decode_error
            end
            if keys[key] then
                return nil, nil, "duplicate JSON object key"
            end
            keys[key] = true

            cursor = skip_json_whitespace(text, key_last + 1)
            if text:sub(cursor, cursor) ~= ":" then
                return nil, nil, "missing colon after JSON object key"
            end
            cursor = skip_json_whitespace(text, cursor + 1)
            local value_last, _, value_error = scan_json_value(
                text,
                cursor,
                depth + 1,
                child_json_state(state, key),
                context
            )
            if not value_last then
                return nil, nil, value_error
            end

            cursor = skip_json_whitespace(text, value_last + 1)
            local delimiter = text:sub(cursor, cursor)
            if delimiter == "}" then
                return cursor, "object", nil
            elseif delimiter ~= "," then
                return nil, nil, "invalid JSON object delimiter"
            end
            cursor = skip_json_whitespace(text, cursor + 1)
            if text:sub(cursor, cursor) == "}" then
                return nil, nil, "trailing comma in JSON object"
            end
        end
    elseif char == "[" then
        local cursor = skip_json_whitespace(text, position + 1)
        if text:sub(cursor, cursor) == "]" then
            return cursor, "array", nil
        end

        local index = 0
        while true do
            index = index + 1
            local value_first = cursor
            local child_state = "ignore"
            local previous_group = context.current_group
            local previous_part = context.current_part

            if state == "response_array" then
                local group = { raw_parts = {}, part_count = 0 }
                context.groups[#context.groups + 1] = group
                context.current_group = group
                child_state = "response"
            elseif state == "candidates" and index == 1 then
                child_state = "candidate"
            elseif state == "parts" then
                child_state = "part"
                context.current_part = index
            end

            local value_last, _, value_error = scan_json_value(
                text, value_first, depth + 1, child_state, context)
            if not value_last then
                return nil, nil, value_error
            end

            if state == "parts" and context.current_group then
                if index > MAX_RESPONSE_PARTS then
                    return nil, nil, "JSON Part count exceeded the limit"
                end
                context.current_group.part_count = index
                context.current_group.raw_parts[index]
                    = text:sub(value_first, value_last)
            end
            context.current_group = previous_group
            context.current_part = previous_part

            cursor = skip_json_whitespace(text, value_last + 1)
            local delimiter = text:sub(cursor, cursor)
            if delimiter == "]" then
                return cursor, "array", nil
            elseif delimiter ~= "," then
                return nil, nil, "invalid JSON array delimiter"
            end
            cursor = skip_json_whitespace(text, cursor + 1)
            if text:sub(cursor, cursor) == "]" then
                return nil, nil, "trailing comma in JSON array"
            end
        end
    elseif char == "t" and text:sub(position, position + 3) == "true" then
        return position + 3, "boolean", nil
    elseif char == "f" and text:sub(position, position + 4) == "false" then
        return position + 4, "boolean", nil
    elseif char == "n" and text:sub(position, position + 3) == "null" then
        return position + 3, "null", nil
    elseif char == "-" or char:match("%d") then
        local last, err = scan_json_number(text, position)
        return last, last and "number" or nil, err
    end
    return nil, nil, "invalid JSON value"
end

local function extract_raw_response_parts(text)
    local context = {
        groups = {},
        current_group = nil,
        current_part = nil,
        value_count = 0,
    }
    local first = skip_json_whitespace(text, 1)
    local char = text:sub(first, first)
    local state
    if char == "{" then
        local group = { raw_parts = {}, part_count = 0 }
        context.groups[1] = group
        context.current_group = group
        state = "response"
    elseif char == "[" then
        state = "response_array"
    else
        return nil, "Gemini response root must be an object or array"
    end

    local last, _, err =
        scan_json_value(text, first, 1, state, context)
    if not last then
        return nil, err
    end
    if skip_json_whitespace(text, last + 1) <= #text then
        return nil, "trailing data after Gemini JSON response"
    end
    return context.groups, nil
end

local function copy_value(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}
    for key, item in pairs(value) do
        result[copy_value(key)] = copy_value(item)
    end
    return result
end

local function is_bounded_dense_array(value, max_items)
    if type(value) ~= "table" or #value > max_items then
        return false
    end

    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0
            or key > max_items then
            return false
        end
        count = count + 1
    end
    return count == #value
end

local function stringify_object(value)
    local encoded = jsonc.stringify(value, false)
    if type(encoded) ~= "string" or encoded:match("^%s*%[%s*%]%s*$") then
        return "{}"
    end
    return encoded
end

local function validate_raw_json(text, expected_kind)
    local context = {
        groups = {},
        current_group = nil,
        current_part = nil,
        value_count = 0,
    }
    local first = skip_json_whitespace(text, 1)
    local last, kind, err =
        scan_json_value(text, first, 1, "ignore", context)
    if not last then
        return nil, err
    end
    if skip_json_whitespace(text, last + 1) <= #text then
        return nil, "trailing data after JSON value"
    end
    if expected_kind and kind ~= expected_kind then
        return nil, "expected JSON " .. expected_kind
    end
    return kind, nil
end

local function parse_function_response_with_raw(output)
    local text
    if type(output) == "table" then
        text = jsonc.stringify(output, false)
    else
        text = tostring(output or "")
    end
    text = tostring(text or "")
    local trimmed = text:match("^%s*(.-)%s*$") or ""

    if trimmed:sub(1, 1) == "{" then
        local kind = validate_raw_json(trimmed, "object")
        local ok, parsed = pcall(jsonc.parse, trimmed)
        if kind and ok and type(parsed) == "table" then
            return parsed, trimmed
        end
    end

    if #trimmed > 0 then
        local wrapped = '{"result":' .. trimmed .. "}"
        local kind = validate_raw_json(wrapped, "object")
        local ok, parsed = pcall(jsonc.parse, wrapped)
        if kind and ok and type(parsed) == "table" then
            return parsed, wrapped
        end
    end

    local encoded_text = jsonc.stringify(text, false)
    if type(encoded_text) ~= "string" then
        encoded_text = '""'
    end
    return { result = text }, '{"result":' .. encoded_text .. "}"
end

local function is_json_object_table(value)
    if type(value) ~= "table" then
        return false
    end
    for key in pairs(value) do
        if type(key) ~= "string" then
            return false
        end
    end
    return true
end

local function encode_json_value(value)
    local ok, encoded = pcall(jsonc.stringify, value, false)
    if not ok or type(encoded) ~= "string" then
        return nil, "unsupported JSON value"
    end
    return encoded, nil
end

local SCHEMA_MAP_FIELDS = {
    properties = true,
    definitions = true,
    ["$defs"] = true,
    patternProperties = true,
    dependentSchemas = true,
}

local SCHEMA_SINGLE_FIELDS = {
    items = true,
    additionalProperties = true,
    propertyNames = true,
    ["not"] = true,
    ["if"] = true,
    ["then"] = true,
    ["else"] = true,
    contains = true,
    unevaluatedProperties = true,
}

local SCHEMA_ARRAY_FIELDS = {
    anyOf = true,
    oneOf = true,
    allOf = true,
    prefixItems = true,
}

local encode_schema_json

local function encode_schema_map(value, stack)
    if not is_json_object_table(value) then
        return nil, "Schema map must be a JSON object"
    end
    if stack[value] then
        return nil, "cyclic Schema map"
    end
    stack[value] = true

    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local fields = {}
    for _, key in ipairs(keys) do
        local encoded_key, key_error = encode_json_value(key)
        local encoded_value, value_error =
            encode_schema_json(value[key], stack)
        if not encoded_key or not encoded_value then
            stack[value] = nil
            return nil, key_error or value_error
        end
        fields[#fields + 1] = encoded_key .. ":" .. encoded_value
    end
    stack[value] = nil
    return "{" .. table.concat(fields, ",") .. "}", nil
end

local function encode_schema_array(value, stack)
    if not is_bounded_dense_array(value, MAX_JSON_VALUES) then
        return nil, "Schema alternatives must be a dense array"
    end
    if stack[value] then
        return nil, "cyclic Schema array"
    end
    stack[value] = true

    local items = {}
    for index, schema in ipairs(value) do
        local encoded, encode_error =
            encode_schema_json(schema, stack)
        if not encoded then
            stack[value] = nil
            return nil, encode_error
        end
        items[index] = encoded
    end
    stack[value] = nil
    return "[" .. table.concat(items, ",") .. "]", nil
end

encode_schema_json = function(value, stack)
    if not is_json_object_table(value) then
        return nil, "Schema must be a JSON object"
    end
    stack = stack or {}
    if stack[value] then
        return nil, "cyclic Schema object"
    end
    stack[value] = true

    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local fields = {}
    for _, key in ipairs(keys) do
        local encoded_key, key_error = encode_json_value(key)
        local item = value[key]
        local encoded_value
        local value_error
        if SCHEMA_MAP_FIELDS[key] then
            encoded_value, value_error =
                encode_schema_map(item, stack)
        elseif SCHEMA_ARRAY_FIELDS[key] then
            encoded_value, value_error =
                encode_schema_array(item, stack)
        elseif SCHEMA_SINGLE_FIELDS[key] and type(item) == "table" then
            encoded_value, value_error =
                encode_schema_json(item, stack)
        else
            -- Values such as default/example/enum are ordinary JSON. Do not
            -- reinterpret matching key names inside those user values.
            encoded_value, value_error = encode_json_value(item)
        end
        if not encoded_key or not encoded_value then
            stack[value] = nil
            return nil, key_error or value_error
        end
        fields[#fields + 1] = encoded_key .. ":" .. encoded_value
    end
    stack[value] = nil
    return "{" .. table.concat(fields, ",") .. "}", nil
end

local function encode_tool_declarations(tools)
    if not is_bounded_dense_array(tools, MAX_RESPONSE_PARTS) then
        return nil, "Gemini tools must be a dense array"
    end

    local encoded_groups = {}
    for group_index, group in ipairs(tools) do
        if not is_json_object_table(group) then
            return nil, "Gemini Tool group must be a JSON object"
        end

        local group_keys = {}
        for key in pairs(group) do
            group_keys[#group_keys + 1] = key
        end
        table.sort(group_keys)

        local group_fields = {}
        for _, key in ipairs(group_keys) do
            local encoded_key, key_error = encode_json_value(key)
            local encoded_value
            local value_error
            if key == "functionDeclarations" then
                local declarations = group[key]
                if not is_bounded_dense_array(
                    declarations, MAX_RESPONSE_PARTS) then
                    return nil,
                        "Gemini Function declarations must be a dense array"
                end
                local encoded_declarations = {}
                for declaration_index, declaration
                    in ipairs(declarations) do
                    if not is_json_object_table(declaration) then
                        return nil,
                            "Gemini Function declaration must be an object"
                    end

                    local declaration_keys = {}
                    for declaration_key in pairs(declaration) do
                        declaration_keys[#declaration_keys + 1]
                            = declaration_key
                    end
                    table.sort(declaration_keys)

                    local declaration_fields = {}
                    for _, declaration_key
                        in ipairs(declaration_keys) do
                        local encoded_declaration_key, declaration_key_error =
                            encode_json_value(declaration_key)
                        local encoded_declaration_value
                        local declaration_value_error
                        if declaration_key == "parameters" then
                            encoded_declaration_value,
                                declaration_value_error =
                                encode_schema_json(
                                    declaration[declaration_key])
                        else
                            encoded_declaration_value,
                                declaration_value_error =
                                encode_json_value(
                                    declaration[declaration_key])
                        end
                        if not encoded_declaration_key
                            or not encoded_declaration_value then
                            return nil, declaration_key_error
                                or declaration_value_error
                        end
                        declaration_fields[#declaration_fields + 1] =
                            encoded_declaration_key .. ":"
                            .. encoded_declaration_value
                    end
                    encoded_declarations[declaration_index] =
                        "{" .. table.concat(
                            declaration_fields, ",") .. "}"
                end
                encoded_value = "[" .. table.concat(
                    encoded_declarations, ",") .. "]"
            else
                encoded_value, value_error =
                    encode_json_value(group[key])
            end
            if not encoded_key or not encoded_value then
                return nil, key_error or value_error
                    or ("Failed to encode Gemini Tool group "
                        .. tostring(group_index))
            end
            group_fields[#group_fields + 1] =
                encoded_key .. ":" .. encoded_value
        end
        encoded_groups[group_index] =
            "{" .. table.concat(group_fields, ",") .. "}"
    end
    return "[" .. table.concat(encoded_groups, ",") .. "]", nil
end

local function encode_request_body(body, raw_contents)
    local keys = {}
    for key in pairs(body or {}) do
        if type(key) ~= "string" then
            return nil, "Gemini request body contained a non-string key."
        end
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local fields = {}
    for _, key in ipairs(keys) do
        local encoded_key = jsonc.stringify(key, false)
        if type(encoded_key) ~= "string" then
            return nil, "Failed to encode a Gemini request key."
        end

        local encoded_value
        if key == "contents" then
            local contents = body.contents or {}
            if not is_bounded_dense_array(contents, MAX_STREAM_RECORDS) then
                return nil, "Gemini request contents must be a dense array."
            end
            local items = {}
            for index, content in ipairs(contents) do
                local raw = raw_contents and raw_contents[index]
                if raw ~= nil then
                    raw = tostring(raw)
                    if not validate_raw_json(raw, "object") then
                        return nil,
                            "Stored Gemini provider Content was not valid JSON."
                    end
                    items[#items + 1] = raw
                else
                    local encoded = jsonc.stringify(content, false)
                    if type(encoded) ~= "string" then
                        return nil,
                            "Failed to encode Gemini request Content."
                    end
                    items[#items + 1] = encoded
                end
            end
            encoded_value = "[" .. table.concat(items, ",") .. "]"
        elseif key == "tools" then
            local tools_error
            encoded_value, tools_error =
                encode_tool_declarations(body[key])
            if not encoded_value then
                return nil, "Failed to encode Gemini Tool schema: "
                    .. tostring(tools_error)
            end
        else
            encoded_value = jsonc.stringify(body[key], false)
            if type(encoded_value) ~= "string" then
                return nil, "Failed to encode Gemini request field: " .. key
            end
        end
        fields[#fields + 1] = encoded_key .. ":" .. encoded_value
    end

    if raw_contents then
        for index in pairs(raw_contents) do
            if type(index) ~= "number" or index < 1
                or index % 1 ~= 0 or index > #(body.contents or {}) then
                return nil, "Gemini raw Content metadata was inconsistent."
            end
        end
    end
    return "{" .. table.concat(fields, ",") .. "}", nil
end

local function build_raw_model_content(raw_parts)
    return '{"role":"model","parts":['
        .. table.concat(raw_parts or {}, ",") .. "]}"
end

local function build_raw_function_call_part(
    name, provider_id, raw_args)
    local encoded_name = jsonc.stringify(tostring(name or ""), false)
    local fields = { '"name":' .. tostring(encoded_name or '""') }
    if provider_id ~= nil and #tostring(provider_id) > 0 then
        local encoded_id =
            jsonc.stringify(tostring(provider_id), false)
        fields[#fields + 1] = '"id":' .. tostring(encoded_id or '""')
    end
    fields[#fields + 1] = '"args":' .. tostring(raw_args or "{}")
    return '{"functionCall":{' .. table.concat(fields, ",") .. "}}"
end

local function build_raw_function_response_part(
    name, provider_id, raw_response)
    local encoded_name = jsonc.stringify(tostring(name or ""), false)
    local fields = { '"name":' .. tostring(encoded_name or '""') }
    if provider_id ~= nil then
        local encoded_id =
            jsonc.stringify(tostring(provider_id), false)
        fields[#fields + 1] = '"id":' .. tostring(encoded_id or '""')
    end
    fields[#fields + 1] = '"response":' .. tostring(raw_response or "{}")
    return '{"functionResponse":{' .. table.concat(fields, ",") .. "}}"
end

local function build_raw_user_content(raw_parts)
    return '{"role":"user","parts":['
        .. table.concat(raw_parts or {}, ",") .. "]}"
end

local function is_mergeable_text_part(part)
    if type(part) ~= "table" or type(part.text) ~= "string"
        or part.thoughtSignature ~= nil then
        return false
    end
    for key in pairs(part) do
        if key ~= "text" and key ~= "thought" then
            return false
        end
    end
    return part.thought == nil or type(part.thought) == "boolean"
end

local gemini = {}

gemini.new = function()
    local obj = {}

    obj.cfg = nil
    obj.format = nil
    obj.mark = {}
    obj.recv_raw_msg = { role = common.role.unknown, message = "" }
    obj._sysmsg_text = nil
    obj._reboot_required = false
    obj._sse_state = response_framer.new_sse(
        MAX_RESPONSE_BYTES, MAX_STREAM_RECORDS)

    obj._parse_error = function(self, message, detail, can_continue)
        return chat_error.build(self, {
            phase = "response_parse",
            kind = "parse_error",
            message = message,
            detail = detail,
            can_continue = can_continue ~= false
                and not self._tool_side_effects_committed,
        })
    end

    obj._clear_tool_cycle = function(self, preserve_side_effects)
        local side_effects_committed = self._tool_side_effects_committed == true
        self.processed_tool_call_ids = {}
        self._processed_tool_results = {}
        self._pending_provider_contents = {}
        self._pending_provider_raw_contents = {}
        self._pending_provider_bytes = 0
        self._active_tool_definitions = nil
        self._request_tools_enabled = false
        self._request_tool_names = {}
        self._request_tool_choice = nil
        self._tool_side_effects_committed = preserve_side_effects
            and side_effects_committed
            or false
    end

    obj._reset_response_state = function(self)
        response_framer.reset_sse(
            self._sse_state, MAX_RESPONSE_BYTES, MAX_STREAM_RECORDS)
        self._response_mode = nil
        self._transport_buffer = ""
        self._response_bytes_received = 0
        self._stream_record_count = 0
        self._response_done = false
        self._terminal_reason = nil
        self._candidate_seen = false
        self._candidate_role = nil
        self._response_id = nil
        self._model_version = nil
        self._provider_parts = {}
        self._provider_raw_parts = {}
        self._provider_text_chunks = {}
        self._answer_text = ""
        self._thinking_text = ""
        self._answer_chunks = {}
        self._thinking_chunks = {}
        self._completed_provider_content = nil
        self._completed_provider_raw_content = nil
        self._completed_tool_calls = {}
        self._completed_tool_message = nil
        self._tool_calls_finalized = false
        self._tool_output_handled = false
        self._usage_metadata = nil
    end

    obj.initialize = function(self, arg, format)
        self.cfg = datactrl.get_ai_service_cfg(arg, { format = format })
        self.format = format
        self._agent_mode = nil
        self._reboot_required = false
        self._request_serial = 0
        self._last_provider_content = nil
        self._last_provider_raw_content = nil
        self._last_provider_answer = nil
        self.mark = {}
        self.recv_raw_msg = { role = common.role.unknown, message = "" }
        self:_clear_tool_cycle()
        self:_reset_response_state()
    end

    obj.init_msg_buffer = function(self)
        self.recv_raw_msg.role = common.role.unknown
        self.recv_raw_msg.message = ""
        self.mark = {}
        self._request_serial = tonumber(self._request_serial or 0) + 1
        -- convert_schema() has already prepared an exact provider-native Tool
        -- continuation. Only reset the parser for the response about to arrive.
        self:_reset_response_state()
    end

    obj.reset_ai_response_framer = function(self)
        self:_reset_response_state()
        if not self._tool_side_effects_committed then
            self:_clear_tool_cycle()
        end
    end

    obj.set_chat_id = function(self, id)
        self.cfg.id = id
    end

    obj.get_config = function(self)
        return self.cfg
    end

    obj.get_format = function(self)
        return self.format
    end

    obj.getformat = function(self)
        return self.format
    end

    obj.get_reboot_required = function(self)
        return self._reboot_required or false
    end

    obj.get_tool_side_effects_committed = function(self)
        return self._tool_side_effects_committed == true
    end

    obj._thinking_visible = function(self)
        local format = self:get_format()
        return common.check_show_thinking_enabled(self)
            and (format == common.ai.format.chat
                or format == common.ai.format.prompt
                or format == common.ai.format.output)
    end

    obj._transform_unified_schema = function(self, chat, followup)
        local contents = {}
        local raw_contents = {}
        local system_buf = {}
        local pending_function_responses = {}
        local pending_function_response_raw_parts = {}
        local messages = chat.messages or {}
        local last_plain_assistant

        for index = #messages, 1, -1 do
            local message = messages[index]
            if tostring(message.role or "") == common.role.assistant
                and not (type(message.tool_calls) == "table"
                    and #message.tool_calls > 0) then
                last_plain_assistant = index
                break
            end
        end

        local function flush_function_responses()
            if #pending_function_responses == 0 then
                return
            end
            contents[#contents + 1] = {
                role = "user",
                parts = pending_function_responses,
            }
            raw_contents[#contents] =
                build_raw_user_content(pending_function_response_raw_parts)
            pending_function_responses = {}
            pending_function_response_raw_parts = {}
        end

        for index, message in ipairs(messages) do
            local role = tostring(message.role or "")
            local text = tostring(message.content or message.message or "")
            local has_tool_calls = type(message.tool_calls) == "table"
                and #message.tool_calls > 0

            if followup and (role == "tool"
                or (role == common.role.assistant and has_tool_calls)) then
                -- The exact model Content and FunctionResponse Content are
                -- appended below. Never reconstruct signed Parts here.
            elseif role == common.role.system then
                flush_function_responses()
                system_buf[#system_buf + 1] = text
            elseif role == common.role.user then
                flush_function_responses()
                contents[#contents + 1] = {
                    role = "user",
                    parts = { { text = text } },
                }
            elseif role == common.role.assistant then
                flush_function_responses()
                if has_tool_calls then
                    local parts = {}
                    local raw_parts = {}
                    for _, tool_call in ipairs(message.tool_calls) do
                        local fn = tool_call["function"] or {}
                        local args = ous.normalize_arguments(fn.arguments)
                        local function_call = {
                            name = tostring(fn.name or ""),
                            args = args,
                        }
                        local id = tostring(tool_call.id or "")
                        if #id > 0 then
                            function_call.id = id
                        end
                        parts[#parts + 1] = {
                            functionCall = function_call,
                        }
                        raw_parts[#raw_parts + 1]
                            = build_raw_function_call_part(
                                function_call.name,
                                function_call.id,
                                stringify_object(args)
                            )
                    end
                    contents[#contents + 1] = {
                        role = "model",
                        parts = parts,
                    }
                    raw_contents[#contents]
                        = build_raw_model_content(raw_parts)
                elseif index == last_plain_assistant
                    and type(self._last_provider_content) == "table"
                    and text == tostring(self._last_provider_answer or "") then
                    contents[#contents + 1]
                        = copy_value(self._last_provider_content)
                    if type(self._last_provider_raw_content) ~= "string" then
                        error("Gemini provider Content lost its raw Part data.")
                    end
                    raw_contents[#contents]
                        = self._last_provider_raw_content
                else
                    contents[#contents + 1] = {
                        role = "model",
                        parts = { { text = text } },
                    }
                end
            elseif role == "tool" then
                local parsed_response, raw_response =
                    parse_function_response_with_raw(text)
                local function_response = {
                    name = tostring(message.name or message.tool_name or ""),
                    response = parsed_response,
                }
                local id = tostring(message.tool_call_id or "")
                if #id > 0 then
                    function_response.id = id
                end
                pending_function_responses[#pending_function_responses + 1] = {
                    functionResponse = function_response,
                }
                pending_function_response_raw_parts[
                    #pending_function_response_raw_parts + 1
                ] = build_raw_function_response_part(
                    function_response.name,
                    function_response.id,
                    raw_response
                )
            end
        end
        flush_function_responses()

        if followup then
            if #self._pending_provider_contents
                > MAX_PENDING_TOOL_CONTENTS then
                error("Gemini Tool continuation exceeded the Content limit.")
            end
            local pending_bytes = 0
            for provider_index, content
                in ipairs(self._pending_provider_contents) do
                contents[#contents + 1] = copy_value(content)
                local raw =
                    self._pending_provider_raw_contents[provider_index]
                if type(raw) ~= "string" then
                    error("Gemini Tool continuation lost raw provider Content.")
                end
                if #raw > MAX_PENDING_TOOL_BYTES - pending_bytes then
                    error("Gemini Tool continuation exceeded the byte limit.")
                end
                pending_bytes = pending_bytes + #raw
                raw_contents[#contents] = raw
            end
            if pending_bytes ~= tonumber(
                self._pending_provider_bytes or 0) then
                error("Gemini Tool continuation byte accounting was inconsistent.")
            end
        end

        if #contents == 0 then
            contents[1] = { role = "user", parts = { { text = "" } } }
        end

        local body = { contents = contents }
        local system_text = table.concat(system_buf, "\n")
        if #system_text == 0 and self._sysmsg_text
            and #tostring(self._sysmsg_text) > 0 then
            system_text = tostring(self._sysmsg_text)
        end
        if #system_text > 0 then
            body.systemInstruction = {
                parts = { { text = system_text } },
            }
        end
        return body, raw_contents
    end

    obj.convert_schema = function(self, chat)
        local followup = type(self._pending_provider_contents) == "table"
            and #self._pending_provider_contents > 0
        if not followup then
            self:_clear_tool_cycle()
        end

        local body, raw_contents =
            self:_transform_unified_schema(chat, followup)
        if self:_thinking_visible() then
            body.generationConfig = {
                thinkingConfig = { includeThoughts = true },
            }
        end
        body = calling.inject_schema(self, body, {
            followup = followup,
            force_none = followup and not self._agent_mode,
        })

        local encoded, encode_error =
            encode_request_body(body, raw_contents)
        if type(encoded) ~= "string" then
            error(encode_error or "Failed to encode Gemini request body.")
        end

        debug:log("oasis.log", "gemini.convert_schema", string.format(
            "contents=%d bytes=%d stream=true thoughts=%s tools=%d followup=%s",
            #(body.contents or {}),
            #encoded,
            tostring(body.generationConfig ~= nil),
            type(body.tools) == "table" and #body.tools or 0,
            tostring(followup)
        ))
        return encoded
    end

    obj.prepare_post_to_server = function(self, easy, callback, form, user_msg_json)
        local endpoint = tostring(self.cfg.endpoint or ""):gsub("/+$", "")
        local url = string.format(
            "%s/v1beta/models/%s:streamGenerateContent?alt=sse",
            endpoint,
            tostring(self.cfg.model or "")
        )

        easy:setopt_url(url)
        easy:setopt_writefunction(callback)
        easy:setopt_httpheader({
            "Content-Type: application/json",
            "Accept: text/event-stream",
            "X-Goog-Api-Key: " .. tostring(self.cfg.api_key or ""),
        })
        easy:setopt_httppost(form)
        easy:setopt_postfields(user_msg_json)
        debug:log("oasis.log", "gemini.prepare_post_to_server",
            string.format("url=%s body_len=%d", url, #tostring(user_msg_json)))
    end

    obj._framing_error = function(self, message, detail)
        return chat_error.build(self, {
            phase = "response_parse",
            kind = "parse_error",
            message = message,
            detail = detail,
            can_continue = not self._tool_side_effects_committed,
        })
    end

    -- Gemini's official stream is SSE. A complete JSON object/array is also
    -- accepted so API errors and compatible non-SSE endpoints remain readable.
    obj.frame_ai_response = function(self, chunk, eof)
        local incoming = tostring(chunk or "")
        local received = tonumber(self._response_bytes_received or 0)
        if #incoming > MAX_RESPONSE_BYTES - received then
            return {}, self:_framing_error(
                "Gemini response exceeded the total size limit.",
                "max_bytes=" .. MAX_RESPONSE_BYTES)
        end
        self._response_bytes_received = received + #incoming

        if self._response_mode == "json" then
            self._transport_buffer = self._transport_buffer .. incoming
            if #self._transport_buffer > MAX_RESPONSE_BYTES then
                return {}, self:_framing_error(
                    "Incomplete Gemini JSON response exceeded the buffer limit.",
                    "max_bytes=" .. MAX_RESPONSE_BYTES)
            end
            if not eof then
                return {}, nil
            end
            local record = self._transport_buffer
            self._transport_buffer = ""
            return record:find("%S") and { record } or {}, nil
        end

        if self._response_mode == nil then
            self._transport_buffer = self._transport_buffer .. incoming
            if #self._transport_buffer > MAX_RESPONSE_BYTES then
                return {}, self:_framing_error(
                    "Incomplete Gemini response exceeded the buffer limit.",
                    "max_bytes=" .. MAX_RESPONSE_BYTES)
            end
            local first = self._transport_buffer:match("^%s*(.)")
            if not first then
                if eof then
                    self._transport_buffer = ""
                end
                return {}, nil
            end
            if first == "{" or first == "[" then
                self._response_mode = "json"
                if not eof then
                    return {}, nil
                end
                local record = self._transport_buffer
                self._transport_buffer = ""
                return { record }, nil
            end

            self._response_mode = "sse"
            local buffered = self._transport_buffer
            self._transport_buffer = ""
            local frames, frame_error = response_framer.push_sse(
                self._sse_state, buffered, eof)
            if frame_error then
                return frames, self:_framing_error(
                    "Gemini SSE framing failed.", frame_error)
            end
            return frames, nil
        end

        local frames, frame_error = response_framer.push_sse(
            self._sse_state, incoming, eof)
        if frame_error then
            return frames, self:_framing_error(
                "Gemini SSE framing failed.", frame_error)
        end
        return frames, nil
    end

    obj._parse_record = function(self, record)
        local text = tostring(record or "")
        local first = text:match("^%s*(.)")
        if first == "{" or first == "[" then
            local raw_groups, raw_error =
                extract_raw_response_parts(text)
            if not raw_groups then
                return nil, self:_parse_error(
                    "Gemini returned structurally invalid JSON.",
                    raw_error)
            end
            local ok, data = pcall(jsonc.parse, text)
            if not ok or type(data) ~= "table" then
                return nil, self:_parse_error(
                    "Gemini returned invalid JSON.",
                    "response_mode=json")
            end
            return data, nil, raw_groups
        end

        local data_parts = {}
        for line in (text .. "\n"):gmatch("(.-)\n") do
            if line:sub(1, 1) ~= ":" and #line > 0 then
                local field, value = line:match("^([^:]+):%s?(.*)$")
                if field == "data" then
                    data_parts[#data_parts + 1] = value or ""
                elseif field ~= "event" and field ~= "id" and field ~= "retry" then
                    return nil, self:_parse_error(
                        "Gemini returned a malformed SSE event.",
                        "field=" .. tostring(field or line))
                end
            end
        end

        if #data_parts == 0 then
            return { _oasis_keepalive = true }, nil
        end
        local data_text = table.concat(data_parts, "\n")
        if data_text == "[DONE]" then
            return { _oasis_done_marker = true }, nil
        end
        local raw_groups, raw_error =
            extract_raw_response_parts(data_text)
        if not raw_groups then
            return nil, self:_parse_error(
                "Gemini SSE event contained structurally invalid JSON.",
                raw_error)
        end
        local ok, data = pcall(jsonc.parse, data_text)
        if not ok or type(data) ~= "table" then
            return nil, self:_parse_error(
                "Gemini SSE event contained invalid JSON.",
                "event_bytes=" .. #data_text)
        end
        return data, nil, raw_groups
    end

    obj._api_error = function(self, response)
        if type(response) ~= "table" or response.error == nil then
            return nil
        end

        local provider_message
        local detail
        if type(response.error) == "table" then
            provider_message = tostring(
                response.error.message or "Gemini API error")
            detail = response.error.status or response.error.code
        else
            provider_message = tostring(response.error)
        end
        return chat_error.api_error(self, provider_message, {
            detail = detail,
            can_continue = not self._tool_side_effects_committed,
        })
    end

    obj._check_response_identity = function(self, response)
        local response_id = response.responseId
        if response_id ~= nil and #tostring(response_id) > 0 then
            response_id = tostring(response_id)
            if self._response_id and self._response_id ~= response_id then
                return self:_parse_error(
                    "Gemini changed responseId during a streamed response.")
            end
            self._response_id = response_id
        end

        local model_version = response.modelVersion
        if model_version ~= nil and #tostring(model_version) > 0 then
            model_version = tostring(model_version)
            if self._model_version and self._model_version ~= model_version then
                return self:_parse_error(
                    "Gemini changed modelVersion during a streamed response.")
            end
            self._model_version = model_version
        end
        return nil
    end

    obj._extract_completed_tool_calls = function(self)
        local calls = {}
        for part_index, part in ipairs(self._provider_parts) do
            if type(part) == "table" and part.functionCall ~= nil then
                local function_call = part.functionCall
                if type(function_call) ~= "table" then
                    return nil, self:_parse_error(
                        "Gemini returned an invalid FunctionCall Part.",
                        "part_index=" .. part_index)
                end
                if type(function_call.name) ~= "string"
                    or #function_call.name == 0 then
                    return nil, self:_parse_error(
                        "Gemini returned an invalid FunctionCall name.",
                        "part_index=" .. part_index)
                end

                local provider_id
                if function_call.id ~= nil then
                    if type(function_call.id) ~= "string" then
                        return nil, self:_parse_error(
                            "Gemini returned an invalid FunctionCall ID.",
                            "part_index=" .. part_index)
                    end
                    if #function_call.id > 0 then
                        if #function_call.id > MAX_TOOL_CALL_ID_BYTES then
                            return nil, self:_parse_error(
                                "Gemini returned an oversized FunctionCall ID.",
                                "part_index=" .. part_index)
                        end
                        provider_id = function_call.id
                    end
                end
                local internal_id = provider_id
                if not internal_id then
                    internal_id = string.format(
                        "gemini-call-%d-%d",
                        tonumber(self._request_serial or 0),
                        part_index
                    )
                end
                calls[#calls + 1] = {
                    id = internal_id,
                    provider_id = provider_id,
                    name = function_call.name,
                    args = function_call.args,
                    part_index = part_index,
                    provider_part_json =
                        self._provider_raw_parts[part_index],
                }
            end
        end

        if #calls == 0 then
            return calls, nil
        end

        local model = (tostring((self.cfg and self.cfg.model) or "")
            .. " " .. tostring(self._model_version or "")):lower()
        if model:find("gemini%-3") then
            local first_part = self._provider_parts[calls[1].part_index]
            if type(first_part.thoughtSignature) ~= "string"
                or #first_part.thoughtSignature == 0 then
                return nil, self:_parse_error(
                    "Gemini omitted the required thought signature from its first FunctionCall Part.")
            end
        end
        return calls, nil
    end

    obj._complete_response = function(self, finish_reason, finish_message)
        if self._response_done then
            return self:_parse_error(
                "Gemini returned more than one completion reason.")
        end

        finish_reason = tostring(finish_reason or "")
        self._terminal_reason = finish_reason
        if finish_reason ~= "STOP" then
            self._response_done = true
            return chat_error.api_error(self,
                "Gemini stopped before completing the response.", {
                    detail = "finishReason=" .. finish_reason
                        .. ((finish_message and #tostring(finish_message) > 0)
                            and (" message=" .. tostring(finish_message))
                            or ""),
                    can_continue = not self._tool_side_effects_committed,
                })
        end

        for index, chunks in pairs(self._provider_text_chunks) do
            local part = self._provider_parts[index]
            if type(part) ~= "table" or type(chunks) ~= "table" then
                return self:_parse_error(
                    "Gemini retained text Part state was inconsistent.")
            end
            part.text = table.concat(chunks)
            local encoded_part = jsonc.stringify(part, false)
            if type(encoded_part) ~= "string" then
                return self:_parse_error(
                    "Failed to encode a retained Gemini text Part.")
            end
            self._provider_raw_parts[index] = encoded_part
        end
        self._answer_text = table.concat(self._answer_chunks)
        self._thinking_text = table.concat(self._thinking_chunks)
        local calls, call_error = self:_extract_completed_tool_calls()
        if call_error then
            self._response_done = true
            return call_error
        end

        self._response_done = true
        self._completed_provider_content = {
            role = "model",
            parts = copy_value(self._provider_parts),
        }
        self._completed_provider_raw_content =
            build_raw_model_content(self._provider_raw_parts)
        self._completed_tool_calls = calls
        self.recv_raw_msg.role = common.role.assistant
        self.recv_raw_msg.message = self._answer_text

        if #calls == 0 and #self._answer_text > 0 then
            -- Preserve the non-tool thought signature in memory for the next
            -- turn. Chat persistence remains text-only.
            self._last_provider_content
                = copy_value(self._completed_provider_content)
            self._last_provider_raw_content =
                self._completed_provider_raw_content
            self._last_provider_answer = self._answer_text
        end
        return nil
    end

    obj._consume_response = function(self, response, raw_group)
        if type(response) ~= "table" then
            return nil, self:_parse_error(
                "Gemini returned a non-object response.")
        end
        raw_group = raw_group or { raw_parts = {}, part_count = 0 }
        if type(raw_group) ~= "table"
            or type(raw_group.raw_parts) ~= "table"
            or type(raw_group.part_count) ~= "number" then
            return nil, self:_parse_error(
                "Gemini raw response metadata was inconsistent.")
        end

        local api_error = self:_api_error(response)
        if api_error then
            return nil, api_error
        end
        local identity_error = self:_check_response_identity(response)
        if identity_error then
            return nil, identity_error
        end

        local prompt_feedback = response.promptFeedback
        if type(prompt_feedback) == "table"
            and prompt_feedback.blockReason ~= nil
            and #tostring(prompt_feedback.blockReason) > 0
            and tostring(prompt_feedback.blockReason)
                ~= "BLOCK_REASON_UNSPECIFIED" then
            return nil, chat_error.api_error(self,
                "Gemini blocked the prompt.", {
                    detail = "blockReason="
                        .. tostring(prompt_feedback.blockReason),
                    can_continue = not self._tool_side_effects_committed,
                })
        end

        if response.usageMetadata ~= nil then
            if type(response.usageMetadata) ~= "table" then
                return nil, self:_parse_error(
                    "Gemini returned invalid usage metadata.")
            end
            self._usage_metadata = copy_value(response.usageMetadata)
        end

        local candidates = response.candidates
        if candidates == nil then
            if raw_group.part_count ~= 0 then
                return nil, self:_parse_error(
                    "Gemini raw Parts did not match the parsed response.")
            end
            return { answer = "", thinking = "" }, nil
        end
        if not is_bounded_dense_array(candidates, 1) then
            return nil, self:_parse_error(
                "Gemini returned an invalid candidate list.",
                "expected_candidates=1")
        end
        if #candidates == 0 then
            if raw_group.part_count ~= 0 then
                return nil, self:_parse_error(
                    "Gemini raw Parts did not match the parsed response.")
            end
            return { answer = "", thinking = "" }, nil
        end
        if self._response_done then
            return nil, self:_parse_error(
                "Gemini returned candidate data after completion.")
        end

        local candidate = candidates[1]
        if type(candidate) ~= "table" then
            return nil, self:_parse_error(
                "Gemini returned an invalid candidate.")
        end
        if candidate.index ~= nil and tonumber(candidate.index) ~= 0 then
            return nil, self:_parse_error(
                "Gemini changed the selected candidate index.",
                "index=" .. tostring(candidate.index))
        end
        self._candidate_seen = true

        local answer_parts = {}
        local thinking_parts = {}
        local content = candidate.content
        if content ~= nil then
            if type(content) ~= "table" then
                return nil, self:_parse_error(
                    "Gemini returned invalid candidate content.")
            end
            if content.role ~= nil then
                local role = tostring(content.role)
                if role ~= "model" then
                    return nil, self:_parse_error(
                        "Gemini returned non-model candidate content.",
                        "role=" .. role)
                end
                if self._candidate_role and self._candidate_role ~= role then
                    return nil, self:_parse_error(
                        "Gemini changed candidate role during the response.")
                end
                self._candidate_role = role
            end

            local parts = content.parts
            if parts ~= nil then
                if not is_bounded_dense_array(parts, MAX_RESPONSE_PARTS) then
                    return nil, self:_parse_error(
                        "Gemini returned an invalid or oversized Part list.",
                        "max_parts=" .. MAX_RESPONSE_PARTS)
                end
                if raw_group.part_count ~= #parts
                    or not is_bounded_dense_array(
                        raw_group.raw_parts, MAX_RESPONSE_PARTS) then
                    return nil, self:_parse_error(
                        "Gemini raw Parts did not match the parsed Part list.")
                end
                for part_index, part in ipairs(parts) do
                    if type(part) ~= "table" then
                        return nil, self:_parse_error(
                            "Gemini returned an invalid Part.")
                    end
                    if part.thought ~= nil and type(part.thought) ~= "boolean" then
                        return nil, self:_parse_error(
                            "Gemini returned an invalid thought marker.")
                    end
                    if part.thoughtSignature ~= nil
                        and (type(part.thoughtSignature) ~= "string"
                            or #part.thoughtSignature == 0) then
                        return nil, self:_parse_error(
                            "Gemini returned an invalid thought signature.")
                    end

                    local previous =
                        self._provider_parts[#self._provider_parts]
                    local merge = is_mergeable_text_part(previous)
                        and is_mergeable_text_part(part)
                        and (previous.thought == true)
                            == (part.thought == true)
                    if merge then
                        local chunks = self._provider_text_chunks[
                            #self._provider_parts
                        ]
                        if type(chunks) ~= "table" then
                            chunks = { previous.text }
                            self._provider_text_chunks[
                                #self._provider_parts
                            ] = chunks
                        end
                        chunks[#chunks + 1] = part.text
                    else
                        if #self._provider_parts >= MAX_RESPONSE_PARTS then
                            return nil, self:_parse_error(
                                "Gemini response contained too many retained Parts.",
                                "max_parts=" .. MAX_RESPONSE_PARTS)
                        end
                        self._provider_parts[#self._provider_parts + 1]
                            = copy_value(part)
                        self._provider_raw_parts[
                            #self._provider_raw_parts + 1
                        ] = raw_group.raw_parts[part_index]
                        if is_mergeable_text_part(part) then
                            self._provider_text_chunks[
                                #self._provider_parts
                            ] = { part.text }
                        end
                    end
                    if part.text ~= nil then
                        if type(part.text) ~= "string" then
                            return nil, self:_parse_error(
                                "Gemini returned non-string text.")
                        end
                        if part.thought == true then
                            self._thinking_chunks[
                                #self._thinking_chunks + 1
                            ] = part.text
                            thinking_parts[#thinking_parts + 1] = part.text
                        else
                            self._answer_chunks[
                                #self._answer_chunks + 1
                            ] = part.text
                            answer_parts[#answer_parts + 1] = part.text
                        end
                    end
                end
            end
        elseif raw_group.part_count ~= 0 then
            return nil, self:_parse_error(
                "Gemini raw Parts did not match missing candidate content.")
        end

        if content ~= nil and content.parts == nil
            and raw_group.part_count ~= 0 then
            return nil, self:_parse_error(
                "Gemini raw Parts did not match missing content Parts.")
        end

        if candidate.finishReason ~= nil then
            local completion_error = self:_complete_response(
                candidate.finishReason, candidate.finishMessage)
            if completion_error then
                return nil, completion_error
            end
        end

        local function_call_count = 0
        for _, part in ipairs(content and content.parts or {}) do
            if type(part) == "table" and part.functionCall ~= nil then
                function_call_count = function_call_count + 1
            end
        end
        debug:log("oasis.log", "gemini.recv_ai_msg", string.format(
            "record=%d parts=%d answer_len=%d thinking_len=%d function_calls=%d finish=%s",
            tonumber(self._stream_record_count or 0),
            type(content) == "table" and #(content.parts or {}) or 0,
            #table.concat(answer_parts),
            #table.concat(thinking_parts),
            function_call_count,
            tostring(candidate.finishReason or "")
        ))

        return {
            answer = table.concat(answer_parts),
            thinking = table.concat(thinking_parts),
        }, nil
    end

    obj._build_output = function(self, delta)
        local answer = tostring(delta and delta.answer or "")
        local thinking = tostring(delta and delta.thinking or "")
        local visible_thinking = self:_thinking_visible() and thinking or ""

        if #answer > 0 then
            local message = {
                role = common.role.assistant,
                content = answer,
            }
            if #visible_thinking > 0 then
                message.thinking = visible_thinking
            end
            return tostring(misc.markdown(self.mark, answer) or ""),
                jsonc.stringify({ message = message }, false),
                self.recv_raw_msg,
                false
        end
        if #visible_thinking > 0 then
            return visible_thinking,
                jsonc.stringify({
                    type = "thinking",
                    content = visible_thinking,
                }, false),
                self.recv_raw_msg,
                false
        end
        return "", "", self.recv_raw_msg, false
    end

    obj.recv_ai_msg = function(self, record)
        local data, parse_error, raw_groups = self:_parse_record(record)
        if not data then
            return nil, nil, self.recv_raw_msg, false, parse_error
        end
        if data._oasis_done_marker or data._oasis_keepalive then
            return "", "", self.recv_raw_msg, false
        end

        self._stream_record_count = self._stream_record_count + 1
        if self._stream_record_count > MAX_STREAM_RECORDS then
            return nil, nil, self.recv_raw_msg, false, self:_parse_error(
                "Gemini response exceeded the event limit.",
                "max_events=" .. MAX_STREAM_RECORDS)
        end

        local combined = { answer = "", thinking = "" }
        if #data > 0 then
            if not is_bounded_dense_array(data, MAX_STREAM_RECORDS) then
                return nil, nil, self.recv_raw_msg, false,
                    self:_parse_error(
                        "Gemini returned an invalid JSON response array.")
            end
            if not is_bounded_dense_array(
                raw_groups, MAX_STREAM_RECORDS)
                or #raw_groups ~= #data then
                return nil, nil, self.recv_raw_msg, false,
                    self:_parse_error(
                        "Gemini raw response array metadata was inconsistent.")
            end
            for index, response in ipairs(data) do
                local delta, response_error =
                    self:_consume_response(response, raw_groups[index])
                if response_error then
                    return nil, nil, self.recv_raw_msg, false, response_error
                end
                combined.answer = combined.answer
                    .. tostring(delta and delta.answer or "")
                combined.thinking = combined.thinking
                    .. tostring(delta and delta.thinking or "")
            end
        else
            if not is_bounded_dense_array(raw_groups, 1)
                or #raw_groups ~= 1 then
                return nil, nil, self.recv_raw_msg, false,
                    self:_parse_error(
                        "Gemini raw response metadata was inconsistent.")
            end
            local delta, response_error =
                self:_consume_response(data, raw_groups[1])
            if response_error then
                return nil, nil, self.recv_raw_msg, false, response_error
            end
            combined = delta
        end
        return self:_build_output(combined)
    end

    obj.validate_ai_response_complete = function(self)
        if self._response_done and self._terminal_reason == "STOP"
            and self._candidate_seen then
            return nil
        end
        return self:_parse_error(
            "AI response ended before Gemini reported completion.",
            string.format("records=%d finishReason=%s",
                tonumber(self._stream_record_count or 0),
                tostring(self._terminal_reason or "none")))
    end

    obj.finalize_ai_response = function(self)
        if self._tool_calls_finalized then
            return nil
        end
        self._tool_calls_finalized = true

        local calls = self._completed_tool_calls or {}
        if #calls == 0 then
            -- Keep the side-effect guard until the final answer has been
            -- accepted and stored. A fresh request clears it in convert_schema.
            self:_clear_tool_cycle(true)
            return nil
        end
        if not self._request_tools_enabled then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "function_calling",
                kind = "unsupported_feature",
                message = "Gemini requested a tool when Function Calling was disabled.",
                can_continue = false,
            })
        end

        local ok, plain, response, speaker, used, process_error = pcall(function()
            return calling.process(self, calls)
        end)
        if not ok then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "tool_execution",
                kind = "tool_error",
                message = "Failed while executing a Gemini tool call.",
                detail = tostring(plain),
                can_continue = false,
            })
        end
        if process_error then
            return nil, nil, nil, false, process_error
        end
        if type(speaker) == "table" then
            speaker.content = self._answer_text
        end
        self._completed_tool_message = speaker
        return plain, response, speaker, used
    end

    obj.handle_tool_output = function(self, tool_info, chat)
        if self._tool_output_handled or type(chat) ~= "table" then
            return false
        end
        if type(tool_info) ~= "string"
            or #tool_info > MAX_PENDING_TOOL_BYTES then
            return false
        end

        local info
        local parsed, value = pcall(jsonc.parse, tool_info)
        if parsed and type(value) == "table" then
            info = value
        end
        local outputs = info and info.tool_outputs
        local calls = self._completed_tool_calls or {}
        if type(outputs) ~= "table" or #outputs == 0 or #outputs ~= #calls
            or type(self._completed_provider_content) ~= "table"
            or type(self._completed_provider_raw_content) ~= "string" then
            return false
        end

        local output_by_id = {}
        for _, output in ipairs(outputs) do
            local internal_id = tostring(
                output.tool_call_id or output.id or "")
            if #internal_id == 0 or output_by_id[internal_id] ~= nil
                or output.output == nil then
                return false
            end
            output_by_id[internal_id] = output
        end

        local tool_calls = {}
        local function_response_parts = {}
        local raw_function_response_parts = {}
        local tool_results = {}
        for _, call in ipairs(calls) do
            local output = output_by_id[call.id]
            if type(output) ~= "table"
                or tostring(output.name or "") ~= tostring(call.name or "") then
                return false
            end

            local sanitized_output, sanitize_err =
                ous.sanitize_tool_output_for_ai(output.output)
            if not sanitized_output then
                debug:log("oasis.log", "gemini.handle_tool_output",
                    "Rejecting tool output for AI continuation: "
                    .. tostring(sanitize_err))
                return false
            end

            tool_calls[#tool_calls + 1] = {
                id = call.id,
                type = "function",
                ["function"] = {
                    name = call.name,
                    arguments = stringify_object(call.args),
                },
            }
            local parsed_response, raw_response =
                parse_function_response_with_raw(sanitized_output)
            local function_response = {
                name = call.name,
                response = parsed_response,
            }
            if call.provider_id then
                function_response.id = call.provider_id
            end
            function_response_parts[#function_response_parts + 1] = {
                functionResponse = function_response,
            }
            raw_function_response_parts[
                #raw_function_response_parts + 1
            ] = build_raw_function_response_part(
                call.name, call.provider_id, raw_response)
            tool_results[#tool_results + 1] = {
                id = call.id,
                name = call.name,
                content = sanitized_output,
            }
        end

        local raw_response_content =
            build_raw_user_content(raw_function_response_parts)
        local pending_count = #self._pending_provider_contents
        local pending_bytes =
            tonumber(self._pending_provider_bytes or 0)
        local added_bytes = #self._completed_provider_raw_content
            + #raw_response_content
        if pending_count > MAX_PENDING_TOOL_CONTENTS - 2
            or pending_bytes > MAX_PENDING_TOOL_BYTES - added_bytes then
            return false
        end

        chat.messages = chat.messages or {}
        local original_count = #chat.messages
        local setup_ok, setup_result = pcall(function()
            return ous.setup_msg(self, chat, {
                role = common.role.assistant,
                content = self._answer_text,
                tool_calls = tool_calls,
            })
        end)
        local added = setup_ok and setup_result == true
        if added then
            for _, result in ipairs(tool_results) do
                setup_ok, setup_result = pcall(function()
                    return ous.setup_msg(self, chat, {
                        role = "tool",
                        tool_call_id = result.id,
                        name = result.name,
                        content = result.content,
                    })
                end)
                if not setup_ok or setup_result ~= true then
                    added = false
                    break
                end
            end
        end
        if not added then
            while #chat.messages > original_count do
                table.remove(chat.messages)
            end
            return false
        end

        -- Agent mode may produce several Function Calling steps in one user
        -- turn. Keep every signed model Content and matching FunctionResponse
        -- Content in order; Gemini validates all Function Call signatures
        -- since the most recent ordinary user message. The raw JSON is the
        -- authoritative request representation; lightweight table placeholders
        -- avoid retaining a second expanded copy of the Agent history.
        local model_content_index = #self._pending_provider_contents + 1
        self._pending_provider_contents[model_content_index]
            = { role = "model" }
        self._pending_provider_raw_contents[model_content_index]
            = self._completed_provider_raw_content

        local response_content_index = #self._pending_provider_contents + 1
        self._pending_provider_contents[response_content_index] = {
            role = "user",
        }
        self._pending_provider_raw_contents[response_content_index]
            = raw_response_content
        self._pending_provider_bytes = pending_bytes + added_bytes
        self._tool_output_handled = true
        self._reboot_required = self._reboot_required or info.reboot == true
        return true
    end

    obj.handle_tool_result = function(self, chat, speaker, msg)
        return calling.convert_tool_result(chat, speaker, msg)
    end

    obj.handle_tool_call = function(self, chat, speaker, msg)
        return calling.convert_tool_call(chat, speaker, msg)
    end

    obj.setup_msg = function(_, chat, speaker)
        if not speaker or not speaker.role then
            return false
        end
        if not speaker.message or #speaker.message == 0 then
            return false
        end
        chat.messages = chat.messages or {}
        table.insert(chat.messages, {
            role = speaker.role,
            content = speaker.message,
            name = speaker.name,
        })
        return true
    end

    obj.append_chat_data = function(self, chat)
        local message = {}
        message.id = self.cfg.id
        message.role1 = chat.messages[#chat.messages - 1].role
        message.content1 = chat.messages[#chat.messages - 1].content
        message.role2 = chat.messages[#chat.messages].role
        message.content2 = chat.messages[#chat.messages].content
        util.ubus("oasis.chat", "append", message)
    end

    return obj
end

return gemini.new()
