m = Map("aihelper", nil)

storage = m:section(TypedSection, "storage")
storage.addremove = false
storage.removable = false

function storage:filter(value)
    return value
end

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

service = m:section(TypedSection, "service")
service.addremove = true

function service:filter(value)
    return value
end

name = service:option(Value, "name", "Service Name")
endpoint = service:option(Value, "url", "Endpoint")
api_key = service:option(Value, "api_key", "API Key")
api_key.password = true
model = service:option(Value, "model", "Model")

return m