-- Durable chat format. Provider input is always projected from this document;
-- imported metadata and original tool output must never become provider input.
local jsonc = require("luci.jsonc")
local M = { VERSION = 2, MAX_BYTES = 4 * 1024 * 1024 }

local function array(value, limit)
    if type(value) ~= "table" then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
    end
    return count == #value and count <= limit
end

local function text(value, limit)
    return type(value) == "string" and #value <= (limit or M.MAX_BYTES)
end

function M.identifier(value)
    return text(value, 96) and #value > 0 and value:match("^[%w_-]+$") ~= nil
end

local function bounded_nesting(raw)
    -- Bound nesting before passing untrusted imports to the C JSON decoder.
    local depth, quoted, escaped = 0, false, false
    for i = 1, #raw do
        local c = raw:sub(i, i)
        if quoted then
            if escaped then escaped = false
            elseif c == "\\" then escaped = true
            elseif c == '"' then quoted = false end
        elseif c == '"' then quoted = true
        elseif c == "{" or c == "[" then
            depth = depth + 1
            if depth > 48 then return false end
        elseif c == "}" or c == "]" then depth = depth - 1 end
    end
    return true
end

local function json(value)
    if not text(value) or not bounded_nesting(value) then return false end
    local ok, parsed = pcall(jsonc.parse, value)
    return ok and (parsed ~= nil or value:match("^%s*null%s*$") ~= nil)
end

local function keys(value, allowed)
    if type(value) ~= "table" then return false end
    for key in pairs(value) do if not allowed[key] then return false end end
    return true
end

function M.validate(doc)
    if type(doc) ~= "table" or not array(doc.messages, 16384) then
        return nil, "Chat messages must be a bounded array."
    end
    if doc.format_version ~= nil and doc.format_version ~= M.VERSION then
        return nil, "Unsupported chat format version."
    end
    for _, message in ipairs(doc.messages) do
        if type(message) ~= "table" or not text(message.role, 32)
            or not text(message.content) then return nil, "Invalid chat message." end
        if doc.format_version == M.VERSION and
            (not keys(message, {role=true, content=true}) or
             not ({system=true, user=true, assistant=true})[message.role]) then
            return nil, "Version 2 messages contain conversation text only."
        end
    end
    if doc.format_version == nil then return true end
    if not keys(doc, {format_version=true, messages=true, turns=true, revision=true,
        last_operation_id=true}) or not array(doc.turns, 8192) then
        return nil, "Invalid chat document fields."
    end
    if doc.revision ~= nil and (type(doc.revision) ~= "number" or doc.revision < 0
        or doc.revision % 1 ~= 0 or doc.revision > 2147483647) then
        return nil, "Invalid chat revision."
    end
    if doc.last_operation_id ~= nil and not M.identifier(doc.last_operation_id) then
        return nil, "Invalid operation ID."
    end
    local ids, users = {}, {}
    local function unique(id)
        if not M.identifier(id) or ids[id] then return false end
        ids[id] = true
        return true
    end
    local last_user = 0
    for _, turn in ipairs(doc.turns) do
        if not keys(turn, {id=true, user_message=true, status=true, requests=true})
            or not unique(turn.id) or type(turn.user_message) ~= "number"
            or turn.user_message % 1 ~= 0 or turn.user_message <= last_user
            or not doc.messages[turn.user_message]
            or doc.messages[turn.user_message].role ~= "user"
            or users[turn.user_message] or not array(turn.requests, 128)
            or not ({incomplete=true, completed=true, failed=true, waiting_input=true, waiting_confirmation=true})[turn.status] then
            return nil, "Invalid turn or user-message association."
        end
        users[turn.user_message], last_user = true, turn.user_message
        for _, request in ipairs(turn.requests) do
            if not keys(request, {id=true, provider=true, model=true, status=true,
                tools=true, assistant_text=true, calls=true, error=true})
                or not unique(request.id) or not text(request.provider, 128)
                or not text(request.model, 512) or not text(request.assistant_text)
                or not array(request.calls, 256)
                or not ({incomplete=true, completed=true, failed=true})[request.status]
                or (request.error ~= nil and not text(request.error, 4096)) then
                return nil, "Invalid AI request record."
            end
            local snapshot = request.tools
            if not keys(snapshot, {state=true, definitions_json=true, selection_json=true})
                or not ({none=true, provided=true})[snapshot.state]
                or (snapshot.definitions_json ~= nil and not json(snapshot.definitions_json))
                or (snapshot.selection_json ~= nil and not json(snapshot.selection_json))
                or (snapshot.state == "provided" and snapshot.definitions_json == nil) then
                return nil, "Invalid tool snapshot."
            end
            for _, call in ipairs(request.calls) do
                if not keys(call, {id=true, provider_id=true, name=true, arguments_json=true,
                    status=true, result=true, cached=true}) or not unique(call.id)
                    or not text(call.name, 512) or #call.name == 0
                    or not json(call.arguments_json)
                    or (call.provider_id ~= nil and not text(call.provider_id, 512))
                    or (call.cached ~= nil and type(call.cached) ~= "boolean")
                    or not ({pending=true, running=true, completed=true, failed=true})[call.status] then
                    return nil, "Invalid tool call record."
                end
                local result = call.result
                if result ~= nil then
                    if not keys(result, {original_json=true, ai_json=true, status=true, error=true})
                        or not ({success=true, error=true, unknown=true})[result.status]
                        or (result.original_json ~= nil and not json(result.original_json))
                        or (result.ai_json ~= nil and not json(result.ai_json))
                        or (result.error ~= nil and not text(result.error, 4096))
                        or (result.original_json == nil and result.error == nil)
                        or (call.status ~= "completed" and call.status ~= "failed") then
                        return nil, "Invalid tool result."
                    end
                elseif call.status == "completed" or call.status == "failed" then
                    return nil, "A finished tool call requires a result."
                end
            end
        end
    end
    return true
end

function M.decode(raw)
    if type(raw) ~= "string" or #raw > M.MAX_BYTES then
        return nil, "Chat data exceeds the 4 MiB storage limit."
    end
    if not bounded_nesting(raw) then return nil, "Chat data is nested too deeply." end
    local ok, doc = pcall(jsonc.parse, raw)
    if not ok then return nil, "Invalid chat JSON." end
    local valid, err = M.validate(doc)
    if not valid then return nil, err end
    return doc
end

function M.copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = M.copy(item) end
    return result
end

-- Keep old imports readable, but do not turn imported tool events into live
-- continuation state. Only the current in-memory sequence may supply tools.
function M.conversation(messages)
    local result = {}
    for _, message in ipairs(messages or {}) do
        if ({system=true, user=true, assistant=true})[message.role]
            and type(message.content) == "string" and message.tool_calls == nil then
            result[#result + 1] = {role=message.role, content=message.content}
        end
    end
    return result
end

function M.upgrade(doc)
    if doc.format_version == M.VERSION then return M.copy(doc) end
    return {format_version=M.VERSION, messages=M.conversation(doc.messages), turns={}, revision=doc.revision or 0}
end

function M.document(chat)
    local doc=M.upgrade({format_version=chat.format_version, messages=chat.messages,
        turns=chat.turns, revision=chat.revision, last_operation_id=chat.last_operation_id})
    doc.messages=M.conversation(chat.messages)
    return doc
end

function M.ai_input(chat)
    local result = {model=chat.model, messages={}}
    for _, message in ipairs(chat.messages or {}) do
        local item = {role=message.role, content=message.content}
        -- These fields exist only in the live continuation, never in v2 messages.
        for _, key in ipairs({"tool_calls", "tool_call_id", "name", "tool_name"}) do
            item[key] = M.copy(message[key])
        end
        if item.role == "tool" then
            local clean, err = require("oasis.unified.chat.schema").sanitize_tool_output_for_ai(item.content)
            if not clean then error(err) end
            item.content = clean
        end
        result.messages[#result.messages + 1] = item
    end
    return result
end

-- Extract a top-level JSON value without decoding/re-encoding it. This preserves
-- empty objects vs arrays in argument schemas exactly as sent to the provider.
function M.json_field(raw, wanted)
    local i, size = 1, #raw
    local function whitespace() while i <= size and raw:sub(i,i):match("%s") do i=i+1 end end
    local function string_end()
        i=i+1
        while i <= size do
            local c=raw:sub(i,i); i=i+1
            if c == "\\" then i=i+1 elseif c == '"' then return end
        end
    end
    whitespace(); if raw:sub(i,i) ~= "{" then return nil end; i=i+1
    while i <= size do
        whitespace(); if raw:sub(i,i) ~= '"' then return nil end
        local key_start=i; string_end()
        local key=jsonc.parse(raw:sub(key_start,i-1))
        whitespace(); if raw:sub(i,i) ~= ":" then return nil end; i=i+1; whitespace()
        local start, depth=i, 0
        while i <= size do
            local c=raw:sub(i,i)
            if c == '"' then string_end()
            elseif c == "{" or c == "[" then depth=depth+1; i=i+1
            elseif c == "}" or c == "]" then
                if depth == 0 then break end
                depth=depth-1; i=i+1
            elseif c == "," and depth == 0 then break
            else i=i+1 end
        end
        if key == wanted then return raw:sub(start,i-1):gsub("%s+$", "") end
        if raw:sub(i,i) ~= "," then return nil end; i=i+1
    end
end

return M
