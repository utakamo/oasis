local jsonc = require("luci.jsonc")
local common = require("oasis.common")
local M = {}
local INSTRUCTION = "For router-related requests, proactively use `get_tool_list`. "
    .. "Enable a needed disabled tool with `set_tool_enabled` using its exact server and name. "
    .. "After success, Oasis adds its callable definition to the next model request in the same user turn; "
    .. "then call it directly. Enabling does not execute the tool. "
    .. "Make each Tool Search management call separately and wait for its result."

local function replace(t, name, value)
    local previous = package.loaded[name]
    package.loaded[name] = value
    t:on_cleanup(function() package.loaded[name] = previous end)
end

local function fixture(t)
    local env = { auto = "1", local_tools = true }
    local cursor = {
        get_bool = function() return env.local_tools end,
        get = function(_, _, section, option)
            if section == "support" and option == "tool_auto" then return env.auto end
            if section == "console" then return "custom." .. option end
            if section == "role" then return "fixture.conf" end
        end,
    }
    replace(t, "luci.model.uci", { cursor = function() return cursor end })
    replace(t, "oasis.chat.debug", { log = function() end, dump = function() end })
    replace(t, "oasis.unified.chat.schema", nil)
    env.schema = require("oasis.unified.chat.schema")
    env.service = {
        cfg = { service = "Fixture", model = "fixture", function_calling = "1", sysmsg_key = "custom" },
        format = common.ai.format.output,
        get_config = function(self) return self.cfg end,
        get_format = function(self) return self.format end,
    }
    local previous_loader = common.load_conf_file
    env.conf = { default = { chat = "Default chat", prompt = "Default prompt", call = "Default call" },
        custom = { chat = "Selected system message", prompt = "Selected prompt" },
        general = { auto_title = "Create a title" } }
    common.load_conf_file = function() return env.conf end
    t:on_cleanup(function() common.load_conf_file = previous_loader end)
    return env
end

local function chat()
    return { model = "fixture", messages = {
        { role = "system", content = "Selected system message" },
        { role = "user", content = "Check the router" },
    } }
end

function M.register(harness)
    harness:test("unit", "Auto prompt appends the English tool workflow without changing selected text or history", function(t)
        local env = fixture(t)
        for _, format in ipairs({ common.ai.format.chat, common.ai.format.output,
            common.ai.format.rpc_output, common.ai.format.prompt, common.ai.format.call }) do
            env.service.format = format
            local source = { model = "fixture", messages = { { role = "user", content = "Check the router" } } }
            env.schema.setup_system_msg(env.service, source)
            local selected = source.messages[1].content
            local before = jsonc.stringify(source)
            local outbound = env.schema.with_auto_tool_search_prompt(env.service, source)
            t:assert_equal(selected .. "\n\n" .. INSTRUCTION, outbound.messages[1].content, format)
            t:assert_equal(before, jsonc.stringify(source), "history was changed")
            t:assert_equal("Selected system message", env.conf.custom.chat)
            t:assert_equal("Selected prompt", env.conf.custom.prompt)
            local second = env.schema.with_auto_tool_search_prompt(env.service, source)
            t:assert_equal(outbound.messages[1].content, second.messages[1].content)
            local repeated = env.schema.with_auto_tool_search_prompt(env.service, outbound)
            t:assert_equal(outbound.messages[1].content, repeated.messages[1].content)
        end
    end)

    harness:test("unit", "Auto prompt follows mode switches in existing chats and excludes disabled requests", function(t)
        local env = fixture(t)
        local source = chat()
        env.service.cfg.id = "existing-chat"
        env.schema.setup_system_msg(env.service, source)
        t:assert_equal(2, #source.messages)
        t:assert_contains(env.schema.with_auto_tool_search_prompt(env.service, source).messages[1].content, INSTRUCTION)
        env.auto = "0"
        t:assert_equal(source, env.schema.with_auto_tool_search_prompt(env.service, source))
        env.auto = nil
        t:assert_equal(source, env.schema.with_auto_tool_search_prompt(env.service, source))
        env.auto, env.local_tools = "1", false
        t:assert_equal(source, env.schema.with_auto_tool_search_prompt(env.service, source))
        env.local_tools, env.service.cfg.function_calling = true, "0"
        t:assert_equal(source, env.schema.with_auto_tool_search_prompt(env.service, source))
        env.service.cfg.function_calling, env.service.format = "1", common.ai.format.title
        t:assert_equal(source, env.schema.with_auto_tool_search_prompt(env.service, source))
        env.service.format = common.ai.format.output
        env.service._tool_sequence_context = { active = true, allow_followup_tools = false }
        t:assert_equal(source, env.schema.with_auto_tool_search_prompt(env.service, source))
        env.service._tool_sequence_context.allow_followup_tools = true
        t:assert_equal("Selected system message\n\n" .. INSTRUCTION,
            env.schema.with_auto_tool_search_prompt(env.service, source).messages[1].content)
    end)

    harness:test("unit", "Auto prompt survives management continuations but is absent from the final request", function(t)
        local env = fixture(t)
        local source = chat()
        source.messages[#source.messages + 1] = { role = "tool", content = '{"status":"OK"}' }
        env.schema.setup_system_msg(env.service, source)
        local before = jsonc.stringify(source)
        t:assert_equal(source, env.schema.with_auto_tool_search_prompt(env.service, source))
        env.service._tool_sequence_context = { active = true, allow_followup_tools = true }
        t:assert_equal("Selected system message\n\n" .. INSTRUCTION,
            env.schema.with_auto_tool_search_prompt(env.service, source).messages[1].content)
        env.service._tool_sequence_context.allow_followup_tools = false
        t:assert_equal(source, env.schema.with_auto_tool_search_prompt(env.service, source))
        t:assert_equal(before, jsonc.stringify(source))
    end)

    harness:test("unit", "Auto prompt handles empty and multiple system messages without altering other messages", function(t)
        local env = fixture(t)
        local empty = { messages = { { role = "user", content = "Router" } } }
        local outbound = env.schema.with_auto_tool_search_prompt(env.service, empty)
        t:assert_equal(INSTRUCTION, outbound.messages[1].content)
        t:assert_equal("system", outbound.messages[1].role)
        t:assert_equal(1, #empty.messages)
        local multiple = chat()
        table.insert(multiple.messages, 2, { role = "system", content = "Additional instructions" })
        outbound = env.schema.with_auto_tool_search_prompt(env.service, multiple)
        t:assert_equal("Selected system message", outbound.messages[1].content)
        t:assert_equal("Additional instructions\n\n" .. INSTRUCTION, outbound.messages[2].content)
        t:assert_equal("Check the router", outbound.messages[3].content)
        t:assert_equal("Additional instructions", multiple.messages[2].content)
    end)

    harness:test("unit", "Auto prompt is applied by the shared send path before provider conversion", function(t)
        local env = fixture(t)
        replace(t, "cURL.safe", {})
        replace(t, "oasis.console", {})
        replace(t, "oasis.chat.transfer", nil)
        local transfer = require("oasis.chat.transfer")
        local sent
        transfer.post_to_server = function(_, body) sent = jsonc.parse(body) end
        env.service.init_msg_buffer = function() end
        env.service.convert_schema = function(_, request) return jsonc.stringify(request) end
        local source = chat()
        local _, _, _, err = transfer.send_user_msg(env.service, source)
        t:assert_nil(err)
        t:assert_equal("Selected system message\n\n" .. INSTRUCTION, sent.messages[1].content)
        t:assert_equal("Selected system message", source.messages[1].content)
        env.auto = "0"
        local _, _, _, off_err = transfer.send_user_msg(env.service, source)
        t:assert_nil(off_err)
        t:assert_equal("Selected system message", sent.messages[1].content)
    end)

    harness:test("unit", "Auto instruction reaches every supported provider system-message field", function(t)
        local env = fixture(t)
        replace(t, "oasis.local.tool.client", { get_function_call_schema = function()
            return { { name = "get_tool_list", description = "List tools",
                parameters = { type = "object", properties = {}, required = {} } } }
        end })
        for _, provider in ipairs({ "openai", "openai_responses", "ollama", "anthropic", "gemini" }) do
            replace(t, "oasis.chat.function.calling." .. provider, nil)
            replace(t, "oasis.chat.service." .. provider, nil)
            local service = require("oasis.chat.service." .. provider)
            service.cfg = { service = provider, model = "fixture", function_calling = "1", max_tokens = 1024 }
            service.format = common.ai.format.output
            service._tool_sequence_context = { active = true, allow_followup_tools = true }
            local source = chat()
            local request = env.schema.with_auto_tool_search_prompt(service, source)
            local body = jsonc.parse(service:convert_schema(request))
            local text
            if provider == "anthropic" then text = body.system
            elseif provider == "gemini" then text = body.systemInstruction.parts[1].text
            elseif provider == "openai_responses" then text = body.input[1].content
            else text = body.messages[1].content end
            t:assert_equal("Selected system message\n\n" .. INSTRUCTION, text, provider)
            t:assert_equal("Selected system message", source.messages[1].content, provider .. " history")
            t:assert_true(service._request_tool_names.get_tool_list, provider .. " missing discovery tool")
            service._tool_sequence_context.allow_followup_tools = false
            local final_body = service:convert_schema(env.schema.with_auto_tool_search_prompt(service, source))
            t:assert_not_contains(final_body, INSTRUCTION, provider .. " final request")
        end
    end)
end

return M
