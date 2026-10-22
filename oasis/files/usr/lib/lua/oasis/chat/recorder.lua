-- One recorder per user turn. Runtime provider continuations are separate from
-- durable conversation text. Saving never invokes the model or a local tool.
local jsonc = require("luci.jsonc")
local history = require("oasis.chat.history")
local M = {}

local function storage() return require("oasis.chat.storage") end

local function storage_error(service, message)
    local err = require("oasis.chat.error").build(service, {
        phase="internal", kind="storage_error", can_continue=false,
        message="Failed to save conversation. Completed tools must not be retried.",
        detail=tostring(message),
    })
    local ctx=service._history
    if ctx and not ctx.creating then err.chat_id=ctx.id end
    service._history_error=err
    error(err.display or err.message)
end

local function flush(service)
    local ctx=service._history
    if not ctx then return end
    if service._history_error then error(service._history_error.message) end
    ctx.pending_operation = ctx.pending_operation or storage().new_id()
    local ok, response = pcall(storage().save, ctx.id, ctx.doc, ctx.pending_operation, ctx.creating)
    if not ok or type(response) ~= "table" or response.status ~= "OK" then
        storage_error(service, ok and response and response.desc or response)
    end
    ctx.doc.revision=response.revision
    ctx.doc.last_operation_id=ctx.pending_operation
    ctx.pending_operation=nil
    ctx.creating=false
    ctx.chat.format_version=history.VERSION
    ctx.chat.turns=ctx.doc.turns
    ctx.chat.revision=ctx.doc.revision
    ctx.chat.last_operation_id=ctx.doc.last_operation_id
    service:set_chat_id(ctx.id)
end

function M.start(service, chat)
    if service._history then return end
    local format=service:get_format()
    local formats=require("oasis.common").ai.format
    if format ~= formats.chat and format ~= formats.output and format ~= formats.rpc_output then return end
    service._history_error=nil
    local cfg=service:get_config()
    local doc=history.upgrade({format_version=chat.format_version, messages=chat.messages,
        turns=chat.turns, revision=chat.revision, last_operation_id=chat.last_operation_id})
    doc.messages=history.conversation(chat.messages)
    local user_index
    for i=#doc.messages,1,-1 do if doc.messages[i].role == "user" then user_index=i; break end end
    if not user_index then error("A persisted turn requires a user message.") end
    local is_new=not cfg.id or cfg.id == ""
    local id=is_new and require("oasis.common").generate_chat_id() or cfg.id
    local turn={id=storage().new_id(), user_message=user_index, status="incomplete", requests={}}
    doc.turns[#doc.turns+1]=turn
    service._history={id=id, chat=chat, doc=doc, turn=turn, creating=is_new, new_chat=is_new}
    flush(service)
end

function M.request(service, body)
    local ctx=service._history
    if not ctx then return end
    local definitions=history.json_field(body,"tools")
    local choice=history.json_field(body,"tool_choice") or history.json_field(body,"toolConfig")
    local parsed=definitions and jsonc.parse(definitions)
    local cfg=service:get_config()
    local request={id=storage().new_id(), provider=tostring(cfg.service or ""),
        model=tostring(cfg.model or ""), status="incomplete", assistant_text="", calls={},
        tools={state=type(parsed)=="table" and next(parsed) ~= nil and "provided" or "none",
            definitions_json=definitions, selection_json=choice}}
    ctx.turn.requests[#ctx.turn.requests+1]=request
    ctx.request=request
    flush(service)
end

function M.calls(service, prepared, assistant_text)
    local ctx=service._history
    if not ctx or not ctx.request then return end
    ctx.request.assistant_text=tostring(assistant_text or "")
    for _, call in ipairs(prepared) do
        local record={id=storage().new_id(), provider_id=call.provider_id or call.id or call.call_id,
            name=call.name, arguments_json=call.original_arguments_json or call.normalized_args or "{}",
            status="pending"}
        if call.provider_id_absent then record.provider_id=nil end
        if type(record.arguments_json) ~= "string" then record.arguments_json=jsonc.stringify(record.arguments_json,false) end
        ctx.request.calls[#ctx.request.calls+1]=record
        call.persistence_record=record
    end
    flush(service)
end

local function result_status(value, depth)
    if depth > 8 or type(value) ~= "table" then return "unknown" end
    if value.error ~= nil and value.error ~= false or value.isError == true
        or value.success == false or value.ok == false then return "error" end
    local status=tostring(value.status or ""):lower()
    if status == "error" or status == "failed" or status == "failure" then return "error" end
    local nested=value.result
    if type(nested)=="string" then
        local ok, decoded=pcall(jsonc.parse,nested)
        if ok and type(decoded)=="table" then nested=decoded end
    end
    if type(nested)=="table" then
        local inner=result_status(nested,depth+1)
        if inner ~= "unknown" then return inner end
    end
    if value.success==true or value.ok==true or status=="ok" or status=="success"
        or status=="completed" or nested=="ok" then return "success" end
    -- A returned object alone does not establish the tool's application outcome.
    return "unknown"
end

local function record_result(service, call, raw, exception, cached)
    if not service._history or not call.persistence_record then return end
    local record=call.persistence_record
    local result={status="error"}
    if exception then result.error=tostring(exception):sub(1,4096)
    else
        result.original_json=raw
        result.ai_json=require("oasis.unified.chat.schema").sanitize_tool_output_for_ai(raw)
        result.status=result_status(jsonc.parse(raw),0)
        if not result.ai_json then result.error="Tool result could not be converted for AI input." end
    end
    record.status=(exception or result.status=="error") and "failed" or "completed"
    record.result=result
    if cached then record.cached=true end
    flush(service)
end

function M.execute(service, call, fn)
    if not service._history then return fn() end
    local record=assert(call.persistence_record, "Tool execution has no saved call record.")
    if record.result then error("This tool call has already completed; reload the conversation.") end
    record.status="running"
    flush(service)
    local ok, result=pcall(fn)
    if not ok then record_result(service,call,nil,result); error(result) end
    local encoded_ok, encoded=pcall(jsonc.stringify,result,false)
    if not encoded_ok or type(encoded) ~= "string" then
        record_result(service,call,nil,"Tool returned a non-serializable result.")
        error("Tool returned a non-serializable result.")
    end
    record_result(service,call,encoded)
    return result
end

function M.cached(service, call, raw)
    record_result(service,call,raw,nil,true)
end

function M.response(service, speaker)
    local ctx=service._history
    if not ctx or not ctx.request then return end
    local text=speaker and (speaker.message or speaker.content)
    if type(text)=="string" and text~="" then ctx.request.assistant_text=text end
    ctx.request.status="completed"
    flush(service)
end

function M.complete(service, chat)
    local ctx=service._history
    if not ctx then return nil end
    ctx.doc.messages=history.conversation(chat.messages)
    ctx.turn.status="completed"
    flush(service)
    -- Drop live provider continuation messages at the user-turn boundary.
    chat.messages=history.copy(ctx.doc.messages)
    return ctx.new_chat and {id=ctx.id, title="--"} or nil
end

function M.finish(service, result)
    local ctx=service._history
    if not ctx then return result end
    if not result.ok then
        if not service._history_error then
            ctx.turn.status="failed"
            if ctx.request then
                ctx.request.status="failed"
                ctx.request.error=tostring(result.message or "Processing interrupted."):sub(1,4096)
            end
            pcall(flush,service)
        end
        result.error=service._history_error or result.error
        if result.error then
            if not ctx.creating then result.error.chat_id=ctx.id end
            -- The user turn is already durable; rolling it back and resending is
            -- not a safe retry. A fresh user turn can be started after reload.
            result.error.can_continue=false
            result.error.display=require("oasis.chat.error").format(result.error)
        end
        if not ctx.creating then result.new_chat_info=jsonc.stringify({id=ctx.id,title="--"},false) end
    end
    service._history=nil
    return result
end

return M
