local common = require("oasis.common")

m = Map("oasis", nil)

assist = m:section(TypedSection, "basic")
enable = assist:option(Flag, "enable", "Enable", "Enable setting change suggestions by AI")
enable.enabled = "1"
enable.disabled = "0"

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
name:value(common.ai.service.anthropic.name, common.ai.service.anthropic.name)
name:value(common.ai.service.gemini.name, common.ai.service.gemini.name)

endpoint_ollama = service:option(Value, "ollama_endpoint", "Endpoint")
endpoint_ollama.default = common.ai.service.ollama.endpoint
endpoint_ollama.description = "Please input ollama ip address."
endpoint_ollama:depends("name", common.ai.service.ollama.name)

openai_endpoint = service:option(Value, "openai_endpoint", "Endpoint")
openai_endpoint.default = common.ai.service.openai.endpoint
openai_endpoint:depends("name", common.ai.service.openai.name)

anthropic_endpoint = service:option(Value, "anthropic_endpoint", "Endpoint")
anthropic_endpoint.default = common.ai.service.anthropic.endpoint
anthropic_endpoint:depends("name", common.ai.service.anthropic.name)

gemini_endpoint = service:option(Value, "gemini_endpoint", "Endpoint")
gemini_endpoint.default = common.ai.service.gemini.endpoint
gemini_endpoint:depends("name", common.ai.service.gemini.name)

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