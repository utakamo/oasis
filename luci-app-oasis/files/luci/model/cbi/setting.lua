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

chat_max:value("10", "10")
chat_max:value("20", "20")
chat_max:value("30", "30")
chat_max:value("40", "40")
chat_max:value("50", "50")
chat_max:value("60", "60")
chat_max:value("70", "70")
chat_max:value("80", "80")
chat_max:value("90", "90")
chat_max:value("100", "100")

rollback = m:section(TypedSection, "backup")
monitor_time = rollback:option(ListValue, "rollback_time", "Rollback Time")
monitor_time:value("300", "300")
monitor_time:value("360", "360")
monitor_time:value("420", "420")
monitor_time:value("480", "480")
monitor_time:value("540", "540")
monitor_time:value("600", "600")

service = m:section(TypedSection, "service")
service.addremove = true
service.anonymous = true
service.title = "SERVICE"

name = service:option(ListValue, "name", "Service")
name:value("ollama", "Ollama")
name:value("openai", "OpenAI")
name:value("anthropic", "Anthropic")
name:value("gemini", "Gemini")
name:value("custo-ollama", "Ollama (Custom Endpoint)")
name:value("custom-openai", "OpenAI (Custom Endpoint)")
name:value("custom-anthropic", "Anthropic (Custom Endpoint)")
name:value("custom-gemini", "Gemini (Custom Endpoint)")

ip_addr = service:option(Value, "ipaddr", "IP Address")
ip_addr:depends("name", "ollama")

endpoint = service:option(Value, "endpoint", "Endpoint")
endpoint:depends("name", "custom-ollama")
endpoint:depends("name", "custom-openai")
endpoint:depends("name", "custom-anthropic")
endpoint:depends("name", "custom-gemini")

api_key = service:option(Value, "api_key", "API Key")
api_key.password = true
model = service:option(Value, "model", "Model")

return m