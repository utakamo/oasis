local common = require("oasis.common")

m = Map("oasis", nil)

assist = m:section(TypedSection, "basic")
assist_enable = assist:option(Flag, "enable", "Enable", "Enable setting change suggestions by AI")
assist_enable.enabled = "1"
assist_enable.disabled = "0"

rpc = m:section(TypedSection, "rpc")
rpc_enable = rpc:option(Flag, "enable", "Enable", "Enable setting change rpc")
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
monitor_time = rollback:option(ListValue, "time", "Rollback Time")
for i = 60, 600, 60 do
    monitor_time:value(tostring(i), tostring(i))
end

rollback_enable = rollback:option(Flag, "enable", "Enable", "Rollback Data List")
rollback_enable.enabled = "1"
rollback_enable.disabled = "0"

service = m:section(TypedSection, "service")
service.addremove = true
service.anonymous = true
service.title = "SERVICE"

identifier = service:option(Value, "identifier", "Identifier")
identifier.default = common.generate_service_id()
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
-- name:value(common.ai.service.anthropic.name, common.ai.service.anthropic.name)
-- name:value(common.ai.service.gemini.name, common.ai.service.gemini.name)
-- name:value(common.ai.service.openrouter.name, common.ai.service.openrouter.name)

-- Ollama
ollama_endpoint = service:option(Value, "ollama_endpoint", "Endpoint")
ollama_endpoint.default = common.ai.service.ollama.endpoint
ollama_endpoint:depends("name", common.ai.service.ollama.name)

-- OpenAI
endpoint_type_for_openai = service:option(ListValue, "openai_endpoint_type", "Endpoint Type")
endpoint_type_for_openai:value(common.endpoint.type.default, common.endpoint.type.default)
endpoint_type_for_openai:value(common.endpoint.type.custom, common.endpoint.type.custom)
endpoint_type_for_openai.description = "Default: " .. common.ai.service.openai.endpoint
endpoint_type_for_openai:depends("name", common.ai.service.openai.name)

openai_custom_endpoint = service:option(Value, "openai_custom_endpoint", "Custom Endpoint")
openai_custom_endpoint:depends("openai_endpoint_type", common.endpoint.type.custom)

-- Anthropic
-- endpoint_type_for_anthropic = service:option(ListValue, "anthropic_endpoint_type", "Endpoint Type")
-- endpoint_type_for_anthropic:value(common.endpoint.type.default, common.endpoint.type.default)
-- endpoint_type_for_anthropic:value(common.endpoint.type.custom, common.endpoint.type.custom)
-- endpoint_type_for_anthropic.description = "Default: " .. common.ai.service.anthropic.endpoint
-- endpoint_type_for_anthropic:depends("name", common.ai.service.anthropic.name)

-- anthropic_custom_endpoint = service:option(Value, "anthropic_custom_endpoint", "Custom Endpoint")
-- anthropic_custom_endpoint:depends("anthropic_endpoint_type", common.endpoint.type.custom)

-- Google Gemini
-- endpoint_type_for_gemini = service:option(ListValue, "gemini_endpoint_type", "Endpoint")
-- endpoint_type_for_gemini:value(common.endpoint.type.default, common.endpoint.type.default)
-- endpoint_type_for_gemini:value(common.endpoint.type.custom, common.endpoint.type.custom)
-- endpoint_type_for_gemini.description = "Default: " .. common.ai.service.gemini.endpoint
-- endpoint_type_for_gemini:depends("name", common.ai.service.gemini.name)

-- gemini_custom_endpoint = service:option(Value, "gemini_custom_endpoint", "Endpoint")
-- gemini_custom_endpoint:depends("gemini_endpoint_type", common.endpoint.type.custom)

-- OpenRouter
-- endpoint_type_for_openrouter = service:option(ListValue, "openrouter_endpoint_type", "Endpoint Type")
-- endpoint_type_for_openrouter:value(common.endpoint.type.default, common.endpoint.type.default)
-- endpoint_type_for_openrouter:value(common.endpoint.type.custom, common.endpoint.type.custom)
-- endpoint_type_for_openrouter.description = "Default: " .. common.ai.service.openrouter.endpoint
-- endpoint_type_for_openrouter:depends("name", common.ai.service.openrouter.name)

-- openrouter_custom_endpoint = service:option(Value, "openrouter_custom_endpoint", "Custom Endpoint")
-- openrouter_custom_endpoint:depends("openrouter_endpoint_type", common.endpoint.type.custom)

api_key = service:option(Value, "api_key", "API Key")
api_key.password = true

-- max_tokens (ListValue), only for Anthropic and Custom Anthropic
max_tokens = service:option(ListValue, "max_tokens", "Max Tokens")
for i = 1000, 30000, 1000 do
    max_tokens:value(tostring(i), tostring(i))
end
max_tokens:depends("name", common.ai.service.anthropic.name)

-- thinking (Flag), only for Anthropic and Custom Anthropic
thinking = service:option(Flag, "thinking", "Thinking")
thinking.enabled = "enabled"
thinking.disabled = "disabled"
thinking.default = "disabled"
thinking:depends("name", common.ai.service.anthropic.name)

-- budget_tokens (ListValue), only when thinking is enabled and for Anthropic/Custom Anthropic
budget_tokens = service:option(ListValue, "budget_tokens", "Budget Tokens")
for i = 1000, 20000, 1000 do
    budget_tokens:value(tostring(i), tostring(i))
end
budget_tokens:depends({name = common.ai.service.anthropic.name, thinking = "enabled"})

model = service:option(Value, "model", "Model")

return m