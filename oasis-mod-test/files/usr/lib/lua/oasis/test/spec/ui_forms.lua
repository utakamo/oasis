local form = require("oasis.ui.form")
local M = {}

local function terminal(inputs)
    local index, output = 0, {}
    local function read()
        index = index + 1
        return inputs[index]
    end
    return { print = function(value) output[#output + 1] = value or "" end,
        write = function(value) output[#output + 1] = value end,
        flush = function() end, read_form_line = read, read_secret = read,
        output = output }
end

function M.register(harness)
    harness:test("portable", "UI forms render a non-Wi-Fi definition and validate input types", function(t)
        local term = terminal({ "maybe", "n", "abc", "0", "12", "0", "2", "1,1", "1,2", "private-value" })
        local values, summary = form.read({ title = "Fixture service", fields = {
            { name = "enabled", label = "Enabled", type = "boolean", required = true },
            { name = "timeout", label = "Timeout", type = "integer", min = 1, max = 30, required = true },
            { name = "target", label = "Target", type = "select", required = true,
                choices = { { value = "a", label = "A" }, { value = "b", label = "B" } } },
            { name = "targets", label = "Targets", type = "multiselect", required = true,
                choices = { { value = "a", label = "A" }, { value = "b", label = "B" } } },
            { name = "password", label = "Password", type = "secret", required = true },
        } }, term)
        t:assert_equal(false, values.enabled)
        t:assert_equal(12, values.timeout)
        t:assert_equal("b", values.target)
        t:assert_deep_equal({ "a", "b" }, values.targets)
        t:assert_equal("private-value", values.password)
        t:assert_not_contains(table.concat(term.output, "\n"), "private-value")
        t:assert_not_contains(table.concat(summary, "\n"), "private-value")
    end)

    harness:test("portable", "UI forms preserve false defaults and empty existing secrets", function(t)
        local values = form.read({ title = "Defaults", fields = {
            { name = "enabled", label = "Enabled", type = "boolean", default = false },
            { name = "secret", label = "Keep key", type = "secret" },
        } }, terminal({ "", "" }))
        t:assert_equal(false, values.enabled)
        t:assert_equal("", values.secret)
    end)

    harness:test("portable", "UI forms reject executable fields, secret defaults and duplicate names", function(t)
        for _, fields in ipairs({
            { { name = "x", label = "X", type = "command" } },
            { { name = "x", label = "X", type = "secret", default = "password" } },
            { { name = "x", label = "X", type = "string", command = "reboot" } },
            { { name = "x", label = "X", type = "string" }, { name = "x", label = "X", type = "string" } },
            { { name = "x", label = "X", type = "select", choices = {} } },
        }) do
            t:assert_nil(form.validate({ title = "Invalid", fields = fields }))
        end
    end)

    harness:test("portable", "UI forms cancel on EOF or explicit cancellation and require affirmative confirmation", function(t)
        local definition = { title = "Cancel", fields = { { name = "x", label = "X", type = "string" } } }
        for _, inputs in ipairs({ {}, { "/cancel" } }) do
            local values, err = form.read(definition, terminal(inputs))
            t:assert_nil(values)
            t:assert_equal("cancelled", err)
        end
        t:assert_false(form.confirm(terminal({ "" })))
        t:assert_false(form.confirm(terminal({})))
        t:assert_true(form.confirm(terminal({ "y" })))
        t:assert_not_contains(form.text("SSID\27[2J\r"), "\27")
    end)
end

return M
