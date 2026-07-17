local common = require("oasis.common")
local misc = require("oasis.chat.misc")

m = Map("oasis", nil)

-- check install oasis-mod-retired package
if misc.check_file_exist("/usr/lib/lua/oasis/chat/filter.lua") then
    assist = m:section(TypedSection, "basic")
    assist_enable = assist:option(Flag, "enable", "Enable", "Enable setting change suggestions by AI")
    assist_enable.enabled = "1"
    assist_enable.disabled = "0"
end

rpc = m:section(TypedSection, "rpc")
rpc_enable = rpc:option(Flag, "enable", "Enable")
rpc_enable.enabled = "1"
rpc_enable.disabled = "0"

storage = m:section(TypedSection, "storage")
storage.addremove = false
storage.removable = false

path = storage:option(Value, "path", "Storage Path")
chat_max = storage:option(ListValue, "chat_max", "Chat Max")

for i = 10, 100, 10 do
    chat_max:value(tostring(i), tostring(i))
end

rollback = m:section(TypedSection, "rollback")
monitor_time = rollback:option(ListValue, "time", "Monitor Time")
for i = 60, 600, 60 do
    monitor_time:value(tostring(i), tostring(i))
end

rollback_enable = rollback:option(Flag, "enable", "Storing Data List")
rollback_enable.enabled = "1"
rollback_enable.disabled = "0"

service = m:section(TypedSection, "service")
service.addremove = true
service.anonymous = true
service.title = "SERVICE"

identifier = service:option(Value, "identifier", "Identifier")
identifier.default = common.generate_service_id("urandom")
identifier.rmempty = false
identifier.description = "This value is automatically set and cannot be changed."

function identifier.render(self, section, scope)
    self.readonly = true
    self.disabled = true
    Value.render(self, section, scope)
end

function identifier.formvalue(self, section)
    return self.map:get(section, self.option)
end

name = service:option(ListValue, "name", "Service")
name:value(common.ai.service.ollama.name, common.ai.service.ollama.name)
name:value(common.ai.service.openai.name, common.ai.service.openai.name)
name:value(common.ai.service.anthropic.name, common.ai.service.anthropic.name)
name:value(common.ai.service.gemini.name, common.ai.service.gemini.name)
name:value(common.ai.service.openrouter.name, common.ai.service.openrouter.name)
name:value(common.ai.service.lmstudio.name, common.ai.service.lmstudio.name)

-- Ollama
ollama_endpoint = service:option(Value, "ollama_endpoint", "Endpoint")
ollama_endpoint.default = common.ai.service.ollama.endpoint
ollama_endpoint:depends("name", common.ai.service.ollama.name)

-- LM Studio
lmstudio_endpoint = service:option(Value, "lmstudio_endpoint", "Endpoint")
lmstudio_endpoint.default = common.ai.service.lmstudio.endpoint
lmstudio_endpoint:depends("name", common.ai.service.lmstudio.name)

-- OpenAI
endpoint_type_for_openai = service:option(ListValue, "openai_endpoint_type", "Endpoint Type")
endpoint_type_for_openai:value(common.endpoint.type.default, common.endpoint.type.default)
endpoint_type_for_openai:value(common.endpoint.type.custom, common.endpoint.type.custom)
endpoint_type_for_openai.default = common.endpoint.type.default
endpoint_type_for_openai.rmempty = false
endpoint_type_for_openai.description = "Official endpoints: Responses API "
    .. common.ai.service.openai.responses_endpoint
    .. "; Chat Completions API "
    .. common.ai.service.openai.chat_completions_endpoint
endpoint_type_for_openai:depends("name", common.ai.service.openai.name)

function endpoint_type_for_openai.cfgvalue(self, section)
    local value = self.map:get(section, self.option)
    if value == common.endpoint.type.default or value == common.endpoint.type.custom then
        return value
    end

    local custom_endpoint = self.map:get(section, "openai_custom_endpoint") or ""
    return (#custom_endpoint > 0) and common.endpoint.type.custom or common.endpoint.type.default
end

openai_custom_endpoint = service:option(Value, "openai_custom_endpoint", "Custom Endpoint")
openai_custom_endpoint:depends("openai_endpoint_type", common.endpoint.type.custom)

openai_api_mode = service:option(ListValue, "openai_api_mode", "OpenAI API Mode")
openai_api_mode:value(common.ai.service.openai.api_mode.responses, "Responses API")
openai_api_mode:value(common.ai.service.openai.api_mode.chat_completions, "Chat Completions API")
openai_api_mode.default = common.ai.service.openai.api_mode.chat_completions
openai_api_mode.rmempty = false
openai_api_mode.description = "Chat Completions is the compatibility default. Select Responses API to enable OpenAI reasoning summaries, including for custom endpoints that support it."
openai_api_mode:depends("name", common.ai.service.openai.name)

function openai_api_mode.cfgvalue(self, section)
    local value = self.map:get(section, self.option)
    local modes = common.ai.service.openai.api_mode

    if value == modes.responses or value == modes.chat_completions then
        return value
    end

    -- Merely saving an existing legacy service must not silently migrate it.
    if self.map:get(section, "name") == common.ai.service.openai.name then
        return modes.chat_completions
    end

    return self.default
end

-- Anthropic
endpoint_type_for_anthropic = service:option(ListValue, "anthropic_endpoint_type", "Endpoint Type")
endpoint_type_for_anthropic:value(common.endpoint.type.default, common.endpoint.type.default)
endpoint_type_for_anthropic:value(common.endpoint.type.custom, common.endpoint.type.custom)
endpoint_type_for_anthropic.description = "Default: " .. common.ai.service.anthropic.endpoint
endpoint_type_for_anthropic:depends("name", common.ai.service.anthropic.name)

anthropic_custom_endpoint = service:option(Value, "anthropic_custom_endpoint", "Custom Endpoint")
anthropic_custom_endpoint:depends("anthropic_endpoint_type", common.endpoint.type.custom)

-- Google Gemini
endpoint_type_for_gemini = service:option(ListValue, "gemini_endpoint_type", "Endpoint Type")
endpoint_type_for_gemini:value(common.endpoint.type.default, common.endpoint.type.default)
endpoint_type_for_gemini:value(common.endpoint.type.custom, common.endpoint.type.custom)
endpoint_type_for_gemini.description = "Default: " .. common.ai.service.gemini.endpoint
endpoint_type_for_gemini:depends("name", common.ai.service.gemini.name)

gemini_custom_endpoint = service:option(Value, "gemini_custom_endpoint", "Custom Endpoint")
gemini_custom_endpoint:depends("gemini_endpoint_type", common.endpoint.type.custom)

-- OpenRouter
endpoint_type_for_openrouter = service:option(ListValue, "openrouter_endpoint_type", "Endpoint Type")
endpoint_type_for_openrouter:value(common.endpoint.type.default, common.endpoint.type.default)
endpoint_type_for_openrouter:value(common.endpoint.type.custom, common.endpoint.type.custom)
endpoint_type_for_openrouter.description = "Default: " .. common.ai.service.openrouter.endpoint
endpoint_type_for_openrouter:depends("name", common.ai.service.openrouter.name)

openrouter_custom_endpoint = service:option(Value, "openrouter_custom_endpoint", "Custom Endpoint")
openrouter_custom_endpoint:depends("openrouter_endpoint_type", common.endpoint.type.custom)

api_key = service:option(Value, "api_key", "API Key")
api_key.password = true

function_calling = service:option(Flag, "function_calling", "Function Calling / Tool Use")
function_calling.enabled = "1"
function_calling.disabled = "0"
function_calling.default = "0"
function_calling.description = "Enable only when the selected AI service and model support tool use."

show_thinking = service:option(Flag, "show_thinking", "Show Thinking")
show_thinking.enabled = "1"
show_thinking.disabled = "0"
show_thinking.default = "0"
show_thinking.description = "Display thinking/reasoning text in the CLI and WebUI. This controls display only; it does not enable or disable model thinking. Thinking text is not stored in chat history or returned by the external ubus chat API."

local ANTHROPIC_DEFAULT_MAX_TOKENS = 1024
local ANTHROPIC_MIN_BUDGET_TOKENS = 1024

local function parse_positive_integer(value)
    local text = tostring(value or "")
    if not text:match("^%d+$") then
        return nil, nil
    end

    local number = tonumber(text)
    if not number or number <= 0 or number >= math.huge or number ~= math.floor(number) then
        return nil, nil
    end

    local normalized = text:gsub("^0+", "")
    if normalized == "" then
        normalized = "0"
    end

    return number, normalized
end

local function normalize_anthropic_thinking(value)
    value = tostring(value or ""):lower()
    if value == "disabled" or value == "enabled" or value == "adaptive" then
        return value
    end

    return nil
end

local function form_or_config(option, section, name)
    local target_option = nil
    if name == "max_tokens" then
        target_option = max_tokens
    elseif name == "thinking" then
        target_option = thinking
    elseif name == "budget_tokens" then
        target_option = budget_tokens
    end

    local value = target_option and target_option:formvalue(section) or nil
    if value == nil then
        value = option.map:get(section, name)
    end
    return value
end

local function current_anthropic_thinking(option, section)
    local canonical = form_or_config(option, section, "thinking")
    if canonical ~= nil and canonical ~= "" then
        return normalize_anthropic_thinking(canonical)
    end

    return normalize_anthropic_thinking(option.map:get(section, "type"))
        or "disabled"
end

-- max_tokens (Value), only for Anthropic. Avoid a fixed model-specific upper
-- limit so newer models can expose larger output windows without a UI update.
max_tokens = service:option(Value, "max_tokens", "Max Tokens")
max_tokens.default = tostring(ANTHROPIC_DEFAULT_MAX_TOKENS)
max_tokens.rmempty = false
max_tokens.description = "Positive integer. Manual thinking also requires Budget Tokens to be less than Max Tokens."
max_tokens:depends("name", common.ai.service.anthropic.name)

function max_tokens.validate(self, value, section)
    local number, normalized = parse_positive_integer(value)
    if not number then
        return nil, "Max Tokens must be a positive integer."
    end

    if current_anthropic_thinking(self, section) == "enabled" then
        local budget = form_or_config(self, section, "budget_tokens")
        if budget ~= nil and budget ~= "" then
            local budget_number = parse_positive_integer(budget)
            if budget_number and budget_number >= number then
                return nil, "Max Tokens must be greater than Budget Tokens."
            end
        end
    end

    return normalized
end

-- thinking mode, only for Anthropic. "type" remains a read fallback for
-- legacy service sections but all new writes use the canonical option.
thinking = service:option(ListValue, "thinking", "Thinking Mode")
thinking:value("disabled", "Disabled")
thinking:value("enabled", "Enabled (manual budget)")
thinking:value("adaptive", "Adaptive")
thinking.default = "disabled"
thinking.rmempty = false
thinking.description = "Controls Anthropic model thinking. Show Thinking separately controls whether available thinking summaries are displayed."
thinking:depends("name", common.ai.service.anthropic.name)

function thinking.cfgvalue(self, section)
    local canonical = self.map:get(section, self.option)
    if canonical ~= nil and canonical ~= "" then
        return normalize_anthropic_thinking(canonical) or canonical
    end

    return normalize_anthropic_thinking(self.map:get(section, "type"))
        or self.default
end

function thinking.write(self, section, value)
    local normalized = normalize_anthropic_thinking(value)
    if not normalized then
        return
    end

    self.map:set(section, self.option, normalized)
    if normalized ~= "enabled" then
        self.map:del(section, "budget_tokens")
    end
    return true
end

-- budget_tokens is used only for manually enabled thinking. Adaptive thinking
-- must not send a budget.
budget_tokens = service:option(Value, "budget_tokens", "Budget Tokens")
budget_tokens.rmempty = false
budget_tokens.description = "Integer greater than or equal to 1024 and less than Max Tokens."
budget_tokens:depends({name = common.ai.service.anthropic.name, thinking = "enabled"})

function budget_tokens.validate(self, value, section)
    local number, normalized = parse_positive_integer(value)
    if not number or number < ANTHROPIC_MIN_BUDGET_TOKENS then
        return nil, "Budget Tokens must be an integer greater than or equal to 1024."
    end

    local max_number = parse_positive_integer(
        form_or_config(self, section, "max_tokens")
            or tostring(ANTHROPIC_DEFAULT_MAX_TOKENS)
    )
    if not max_number then
        return nil, "Set a valid Max Tokens value first."
    end

    if number >= max_number then
        return nil, "Budget Tokens must be less than Max Tokens."
    end

    return normalized
end

-- Model
model = service:option(Value, "model", "Model")
model:depends("name", common.ai.service.ollama.name)
model:depends("name", common.ai.service.openai.name)
model:depends("name", common.ai.service.gemini.name)
model:depends("name", common.ai.service.openrouter.name)
model:depends("name", common.ai.service.anthropic.name)
model:depends("name", common.ai.service.lmstudio.name)

return m
