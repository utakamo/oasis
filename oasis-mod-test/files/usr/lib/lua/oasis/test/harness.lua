local M = {}

local Harness = {}
Harness.__index = Harness

local Context = {}
Context.__index = Context

local function value_repr(value, depth, seen)
    local kind = type(value)
    if kind == "string" then
        return string.format("%q", value)
    end
    if kind ~= "table" then
        return tostring(value)
    end

    depth = depth or 0
    seen = seen or {}
    if seen[value] then
        return "<cycle>"
    end
    if depth >= 3 then
        return "{...}"
    end

    seen[value] = true
    local parts = {}
    for key, item in pairs(value) do
        parts[#parts + 1] = {
            key = tostring(key),
            text = "[" .. value_repr(key, depth + 1, seen) .. "]="
                .. value_repr(item, depth + 1, seen),
        }
    end
    table.sort(parts, function(left, right)
        return left.key < right.key
    end)

    local rendered = {}
    for _, part in ipairs(parts) do
        rendered[#rendered + 1] = part.text
    end
    seen[value] = nil
    return "{" .. table.concat(rendered, ", ") .. "}"
end

local function deep_compare(expected, actual, path, seen)
    local expected_type = type(expected)
    local actual_type = type(actual)
    if expected_type ~= actual_type then
        return false, string.format(
            "%s: expected type %s, got %s",
            path,
            expected_type,
            actual_type
        )
    end

    if expected_type ~= "table" then
        if expected == actual or (expected ~= expected and actual ~= actual) then
            return true
        end
        return false, string.format(
            "%s: expected %s, got %s",
            path,
            value_repr(expected),
            value_repr(actual)
        )
    end

    seen = seen or {}
    seen[expected] = seen[expected] or {}
    if seen[expected][actual] then
        return true
    end
    seen[expected][actual] = true

    for key, expected_value in pairs(expected) do
        if actual[key] == nil and expected_value ~= nil then
            return false, string.format(
                "%s[%s]: expected key is missing",
                path,
                value_repr(key)
            )
        end
        local equal, detail = deep_compare(
            expected_value,
            actual[key],
            path .. "[" .. value_repr(key) .. "]",
            seen
        )
        if not equal then
            return false, detail
        end
    end

    for key in pairs(actual) do
        if expected[key] == nil then
            return false, string.format(
                "%s[%s]: unexpected key",
                path,
                value_repr(key)
            )
        end
    end

    return true
end

local function assertion_error(message)
    error(tostring(message or "assertion failed"), 3)
end

function Context:_assertion()
    self.assertions = self.assertions + 1
end

function Context:fail(message)
    self:_assertion()
    assertion_error(message)
end

function Context:assert_true(value, message)
    self:_assertion()
    if value ~= true then
        assertion_error(message or (
            "expected true, got " .. value_repr(value)
        ))
    end
end

function Context:assert_false(value, message)
    self:_assertion()
    if value ~= false then
        assertion_error(message or (
            "expected false, got " .. value_repr(value)
        ))
    end
end

function Context:assert_nil(value, message)
    self:_assertion()
    if value ~= nil then
        assertion_error(message or (
            "expected nil, got " .. value_repr(value)
        ))
    end
end

function Context:assert_not_nil(value, message)
    self:_assertion()
    if value == nil then
        assertion_error(message or "expected a non-nil value")
    end
end

function Context:assert_equal(expected, actual, message)
    self:_assertion()
    if expected ~= actual
        and not (expected ~= expected and actual ~= actual) then
        assertion_error(message or string.format(
            "expected %s, got %s",
            value_repr(expected),
            value_repr(actual)
        ))
    end
end

function Context:assert_deep_equal(expected, actual, message)
    self:_assertion()
    local equal, detail = deep_compare(expected, actual, "value")
    if not equal then
        assertion_error(message and (message .. ": " .. detail) or detail)
    end
end

function Context:assert_type(expected_type, value, message)
    self:_assertion()
    if type(value) ~= expected_type then
        assertion_error(message or string.format(
            "expected type %s, got %s",
            tostring(expected_type),
            type(value)
        ))
    end
end

function Context:assert_contains(value, fragment, message)
    self:_assertion()
    value = tostring(value or "")
    fragment = tostring(fragment or "")
    if not value:find(fragment, 1, true) then
        assertion_error(message or string.format(
            "expected %s to contain %s",
            value_repr(value),
            value_repr(fragment)
        ))
    end
end

function Context:assert_not_contains(value, fragment, message)
    self:_assertion()
    value = tostring(value or "")
    fragment = tostring(fragment or "")
    if value:find(fragment, 1, true) then
        assertion_error(message or string.format(
            "expected %s not to contain %s",
            value_repr(value),
            value_repr(fragment)
        ))
    end
end

function Context:assert_match(pattern, value, message)
    self:_assertion()
    value = tostring(value or "")
    if not value:match(pattern) then
        assertion_error(message or string.format(
            "expected %s to match %s",
            value_repr(value),
            value_repr(pattern)
        ))
    end
end

function Context:assert_error(fn, fragment, message)
    self:_assertion()
    if type(fn) ~= "function" then
        assertion_error("assert_error expects a function")
    end
    local ok, err = pcall(fn)
    if ok then
        assertion_error(message or "expected function to raise an error")
    end
    if fragment and not tostring(err):find(tostring(fragment), 1, true) then
        assertion_error(message or string.format(
            "expected error %s to contain %s",
            value_repr(err),
            value_repr(fragment)
        ))
    end
end

function Context:on_cleanup(fn)
    if type(fn) ~= "function" then
        assertion_error("cleanup must be a function")
    end
    self.cleanups[#self.cleanups + 1] = fn
end

function M.new()
    return setmetatable({ tests = {}, names = {} }, Harness)
end

function Harness:test(suite, name, fn)
    suite = tostring(suite or "")
    name = tostring(name or "")
    if #suite == 0 or #name == 0 or type(fn) ~= "function" then
        error("test registration requires suite, name, and function", 2)
    end

    local identity = suite .. "\0" .. name
    if self.names[identity] then
        error("duplicate test: [" .. suite .. "] " .. name, 2)
    end
    self.names[identity] = true
    self.tests[#self.tests + 1] = {
        suite = suite,
        name = name,
        fn = fn,
    }
end

local function diagnostic(value)
    local text = tostring(value or "unknown failure")
    if #text == 0 then
        print("# unknown failure")
        return
    end
    for line in (text .. "\n"):gmatch("(.-)\n") do
        print("# " .. line)
    end
end

local function run_cleanups(context)
    local errors = {}
    for index = #context.cleanups, 1, -1 do
        local ok, err = pcall(context.cleanups[index])
        if not ok then
            errors[#errors + 1] = "cleanup failed: " .. tostring(err)
        end
    end
    if #errors > 0 then
        return false, table.concat(errors, "\n")
    end
    return true
end

function Harness:run(opts)
    opts = opts or {}
    local selected = {}
    for _, test in ipairs(self.tests) do
        local suite_selected = opts.suites == nil or opts.suites[test.suite]
        local name_selected = not opts.filter
            or test.name:find(opts.filter, 1, true)
            or test.suite:find(opts.filter, 1, true)
        if suite_selected and name_selected then
            selected[#selected + 1] = test
        end
    end

    if #selected == 0 then
        print("Bail out! No tests matched the selected suite and filter.")
        return 2
    end

    print("TAP version 13")
    local failed = 0
    local assertions = 0
    local executed = 0

    for index, test in ipairs(selected) do
        local context = setmetatable({
            assertions = 0,
            cleanups = {},
        }, Context)
        local ok, err = xpcall(function()
            test.fn(context)
        end, debug.traceback)
        local cleanup_ok, cleanup_err = run_cleanups(context)
        if not cleanup_ok then
            if ok then
                err = cleanup_err
            else
                err = tostring(err) .. "\n" .. cleanup_err
            end
            ok = false
        end

        executed = index
        assertions = assertions + context.assertions
        local label = string.format("[%s] %s", test.suite, test.name)
        if ok then
            print(string.format("ok %d - %s", index, label))
            if opts.verbose then
                print(string.format("# assertions: %d", context.assertions))
            end
        else
            failed = failed + 1
            print(string.format("not ok %d - %s", index, label))
            diagnostic(err)
            if opts.fail_fast then
                break
            end
        end
    end

    print(string.format("1..%d", executed))
    print(string.format(
        "# tests=%d assertions=%d failed=%d",
        executed,
        assertions,
        failed
    ))
    return failed == 0 and 0 or 1
end

function M.spy(fn)
    local state = { calls = 0, arguments = {} }
    local wrapped = function(...)
        state.calls = state.calls + 1
        state.arguments[state.calls] = {...}
        if fn then
            return fn(...)
        end
    end
    return wrapped, state
end

return M
