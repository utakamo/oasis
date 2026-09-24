#!/usr/bin/env lua

-- Shared safety policy for provider Function Calling adapters. Provider
-- modules remain responsible for validating their native response shape; this
-- module supplies deterministic argument identity and the sequence-level
-- authorization barrier that must run before any local tool side effect.

local jsonc      = require("luci.jsonc")
local chat_error = require("oasis.chat.error")

local M = {}

local CONTROL_TOOLS = {
    get_tool_list = true,
    set_tool_enabled = true,
    set_tool_disabled = true,
}

local function dense_array_length(value)
    if type(value) ~= "table" then
        return nil
    end

    local count = 0
    local maximum = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil
        end
        count = count + 1
        if key > maximum then
            maximum = key
        end
    end
    if maximum ~= count then
        return nil
    end
    return count
end

M.dense_array_length = dense_array_length

function M.is_json_object(value)
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

-- Argument arrays are not tool-call batches. luci.jsonc represents JSON null
-- entries as absent numeric keys and encodes those holes back to null. Match
-- that representation, including [] for an empty nested table. Keep the
-- dense-array check above for protocol batches, where holes must fail closed.
local function argument_array_length(value)
    local maximum = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key)
            or key == math.huge then
            return nil
        end
        maximum = math.max(maximum, key)
    end
    return maximum
end

function M.canonical_json(value, stack, force_object)
    local value_type = type(value)
    if value_type ~= "table" then
        if value_type ~= "nil" and value_type ~= "boolean"
            and value_type ~= "number" and value_type ~= "string" then
            return nil, "unsupported JSON value"
        end
        if value_type == "number"
            and (value ~= value or value == math.huge or value == -math.huge) then
            return nil, "non-finite number"
        end
        local ok, encoded = pcall(jsonc.stringify, value, false)
        if not ok or type(encoded) ~= "string" then
            return nil, "unsupported JSON value"
        end
        return encoded
    end

    stack = stack or {}
    if stack[value] then
        return nil, "cyclic table"
    end
    stack[value] = true

    local array_length = not force_object and argument_array_length(value)
    if type(array_length) == "number" then
        local items = {}
        for index = 1, array_length do
            local encoded, err = M.canonical_json(value[index], stack)
            if not encoded then
                stack[value] = nil
                return nil, err
            end
            items[#items + 1] = encoded
        end
        stack[value] = nil
        return "[" .. table.concat(items, ",") .. "]"
    end

    if not M.is_json_object(value) then
        stack[value] = nil
        return nil, "mixed or invalid JSON table"
    end

    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local fields = {}
    for _, key in ipairs(keys) do
        local ok, encoded_key = pcall(jsonc.stringify, key, false)
        local encoded_value, err = M.canonical_json(value[key], stack)
        if not ok or type(encoded_key) ~= "string" or not encoded_value then
            stack[value] = nil
            return nil, err or "invalid JSON object key"
        end
        fields[#fields + 1] = encoded_key .. ":" .. encoded_value
    end
    stack[value] = nil
    return "{" .. table.concat(fields, ",") .. "}"
end

function M.canonical_object(value)
    if not M.is_json_object(value) then
        return nil, "value is not a JSON object"
    end
    return M.canonical_json(value, nil, true)
end

-- Execution and history use luci.jsonc's ordinary data representation;
-- canonical ordering is only for identity checks. Only the argument root has
-- an object contract. Never coerce empty nested arrays to objects.
function M.stringify_object(value)
    local canonical, err = M.canonical_object(value)
    if not canonical then
        return nil, err
    end
    if next(value) == nil then
        return "{}"
    end
    local ok, encoded = pcall(jsonc.stringify, value, false)
    if not ok or type(encoded) ~= "string" then
        return nil, "unsupported JSON value"
    end
    return encoded
end

local function sequence_error(self, message, detail)
    return chat_error.build(self, {
        phase = "function_calling",
        kind = "tool_error",
        message = message,
        detail = detail,
        -- This policy runs before the first tool execution. Transport retry is
        -- still safe; transfer.lua will force this false if another path has
        -- already marked a side effect as committed.
        can_continue = true,
    })
end

-- `prepared` must be the provider's fully validated batch. Every entry must
-- expose name and normalized_args; id or call_id is forwarded for diagnostics.
-- Success is true. Failure is nil plus a structured error, and no tool may be
-- executed by the caller after failure.
function M.authorize_tool_batch(self, prepared)
    local context = type(self) == "table" and self._tool_sequence_context or nil
    if type(context) ~= "table" or context.active ~= true then
        return true
    end

    local descriptors = {}
    local has_control = false
    local has_normal = false
    for _, call in ipairs(prepared or {}) do
        local name = tostring(call.name or "")
        local call_id = call.id or call.call_id
        has_control = has_control or CONTROL_TOOLS[name] == true
        has_normal = has_normal or CONTROL_TOOLS[name] ~= true
        descriptors[#descriptors + 1] = {
            id = call_id,
            tool_call_id = call_id,
            name = name,
            arguments = call.normalized_args,
        }
    end

    if has_control and has_normal then
        return nil, sequence_error(self,
            "Tool Search management tools cannot be mixed with normal tools.",
            "Submit management and normal tool calls in separate rounds.")
    end

    local remaining = tonumber(context.remaining_tool_calls)
    if remaining == nil or remaining < 0 or remaining ~= math.floor(remaining) then
        return nil, sequence_error(self,
            "The tool sequence has an invalid tool-call budget.")
    end
    if #descriptors > remaining then
        return nil, sequence_error(self,
            "The tool sequence reached its total tool-call limit.",
            "remaining_tool_calls=" .. tostring(remaining))
    end

    if type(context.authorize_tool_batch) ~= "function" then
        return nil, sequence_error(self,
            "The tool sequence authorization callback is unavailable.")
    end
    local ok, allowed, authorization_error =
        pcall(context.authorize_tool_batch, descriptors)
    if not ok then
        return nil, sequence_error(self,
            "The tool sequence authorization check failed.", tostring(allowed))
    end
    if allowed ~= true then
        if type(authorization_error) == "table" then
            return nil, authorization_error
        end
        return nil, sequence_error(self,
            "The tool sequence rejected the requested tool batch.",
            tostring(authorization_error or "authorization denied"))
    end

    -- The runner recomputes this value for every provider request. Decrement
    -- the adapter-local snapshot as a defense against a second batch being
    -- processed unexpectedly within the same request.
    context.remaining_tool_calls = remaining - #descriptors
    return true
end

return M
