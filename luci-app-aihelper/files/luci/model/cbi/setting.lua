m = Map("aihelper", "Setting")

storage = m:section(TypedSection, "storage")
storage.addremove = true
function storage:filter(value)
    return value
end

path = storage:option(Value, "path", "Storage Path")
chat_max = storage:option(ListValue, "chat_max", "Chat Max")
for i in 100 do
    chat_max:value(i, i)
end

service = m:section(TypedSection, "service")
service.addremove = true
function service:filter(value)
    return value
end

name = service:option(Value, "name", "Service Name")
endpoint = service:option(Value, "url", "Endpoint(URL)")
api_key = service:option(Value, "api_key", "API Key")
model = service:option(Value, "model", "Model")

return m