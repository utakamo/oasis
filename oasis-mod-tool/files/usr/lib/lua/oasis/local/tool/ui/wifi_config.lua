-- Wi-Fi is one registered consumer of the generic CLI form protocol.
local backend = require("oasis.local.tool.wifi_config")
local M = {}

local function step(state, definition)
    state.form = definition
    return { form = definition }
end

local function settings_form(state)
    state.stage = "settings"
    local current = state.targets and state.targets[state.index]
    local fields = {}
    if state.operation == "add" then
        local choices = {}
        for _, device in ipairs(state.snapshot.devices) do
            choices[#choices + 1] = { value = device.section, label = device.section .. " (" .. device.label .. ")" }
        end
        fields[#fields + 1] = { name = "device", label = "Radio", type = "select", required = true, choices = choices }
    end
    fields[#fields + 1] = { name = "ssid", label = "SSID", type = "string", required = true,
        max_length = 32, default = current and current.ssid or nil }
    fields[#fields + 1] = { name = "encryption", label = "Encryption", type = "select", required = true,
        choices = state.snapshot.encryption_options, default = current and current.encryption or "psk2" }
    return step(state, { title = "Wi-Fi settings" .. (current and (" — " .. current.section) or ""), fields = fields })
end

function M.prepare(action, context)
    local allowed = { version = true, type = true, operation = true, band = true }
    for key in pairs(action) do
        if not allowed[key] then return nil, "Unsupported Wi-Fi request field." end
    end
    if action.operation == "add" and action.band ~= context.arguments.band then
        return nil, "Wi-Fi band does not match the executed tool arguments."
    end
    local snapshot = backend.load(action.operation, action.band)
    if not snapshot.ok then return nil, snapshot.error.message end
    local state = { operation = action.operation, band = action.band, snapshot = snapshot,
        payload = { operation = action.operation, revision = snapshot.revision }, index = 1 }
    if action.operation == "add" then
        if #snapshot.devices == 0 then return nil, "No matching Wi-Fi radio is available." end
        state.payload.band = action.band
        return state, settings_form(state)
    end
    local choices = {}
    state.interfaces = {}
    for _, interface in ipairs(snapshot.interfaces) do
        if action.operation == "delete" or interface.encryption_supported then
            state.interfaces[interface.section] = interface
            choices[#choices + 1] = { value = interface.section,
                label = interface.section .. " — " .. interface.ssid .. " (" .. interface.band_label .. ")" }
        end
    end
    if #choices == 0 then return nil, "No supported Wi-Fi access point is available for this operation." end
    state.stage = "choose"
    return state, step(state, { title = action.operation == "delete" and "Delete Wi-Fi access point" or "Edit Wi-Fi access points",
        fields = { { name = "targets", label = "Access point", required = true, choices = choices,
            type = action.operation == "delete" and "select" or "multiselect" } } })
end

local function checked_step(state)
    local checked = backend.validate(state.payload)
    if not checked.ok then
        if checked.error.code ~= "validation_failed" then return { failed = true, error = checked.error.message } end
        local messages = {}
        for _, message in pairs(checked.error.fields or {}) do messages[#messages + 1] = message end
        table.sort(messages)
        return { retry = true, form = state.form, error = #messages > 0 and table.concat(messages, " ") or checked.error.message }
    end
    if state.operation == "update" and state.index < #state.targets then
        state.index = state.index + 1
        return settings_form(state)
    end
    return { ready = true }
end

local function finish_entry(state, passphrase)
    local entry = state.entry
    entry.passphrase = passphrase
    if state.operation == "add" then
        state.payload.device, state.payload.ssid = entry.device, entry.ssid
        state.payload.encryption, state.payload.passphrase = entry.encryption, entry.passphrase
    else
        state.payload.interfaces = state.payload.interfaces or {}
        state.payload.interfaces[state.index] = {
            section = state.targets[state.index].section, ssid = entry.ssid,
            encryption = entry.encryption, passphrase = entry.passphrase,
        }
    end
    return checked_step(state)
end

function M.advance(state, values)
    if state.stage == "choose" then
        if state.operation == "delete" then
            state.payload.section = values.targets
            return checked_step(state)
        end
        state.targets = {}
        for _, section in ipairs(values.targets) do
            local interface = state.interfaces[section]
            if not interface then return { failed = true, error = "Unknown Wi-Fi access point." } end
            state.targets[#state.targets + 1] = interface
        end
        return settings_form(state)
    elseif state.stage == "settings" then
        state.entry = values
        if values.encryption == "none" then return finish_entry(state, "") end
        local current = state.targets and state.targets[state.index]
        local keep_key = current and current.encryption == values.encryption and current.key_configured
        state.stage = "secret"
        return step(state, { title = "Wi-Fi credentials", fields = {
            { name = "passphrase", label = "Passphrase", type = "secret", required = not keep_key,
                max_length = 64, help = keep_key and "Leave empty to keep the existing passphrase."
                    or "Enter a new passphrase for this encryption mode." }
        } })
    elseif state.stage == "secret" then
        return finish_entry(state, values.passphrase or "")
    end
    return { failed = true, error = "Invalid Wi-Fi input step." }
end

function M.apply(state)
    return backend.apply(state.payload)
end

return M
