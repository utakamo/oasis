local harness_module = require("oasis.test.harness")
local registry = require("oasis.test.registry")

local M = {}

local function usage()
    print([[
Usage: oasis_test [options]

Options:
  --suite NAME[,NAME]  Run selected suites (portable, unit, provider, device, all)
  --filter TEXT        Run tests whose suite or name contains TEXT
  --list               List available suites and spec modules
  --fail-fast          Stop after the first failing test
  -v, --verbose        Print per-test assertion counts
  -h, --help           Show this help

Without --suite, the safe portable, unit, and provider suites are run.
The device suite is read-only but requires an installed OpenWrt environment.
]])
end

local function add_suite_names(target, value)
    for name in tostring(value or ""):gmatch("[^,]+") do
        name = name:match("^%s*(.-)%s*$") or ""
        if #name > 0 then
            target[name] = true
        end
    end
end

local function parse_args(argv)
    local opts = {
        requested_suites = {},
        suite_was_set = false,
        fail_fast = false,
        verbose = false,
        list = false,
    }
    local index = 1
    while index <= #argv do
        local value = argv[index]
        if value == "--suite" then
            local suite_value = argv[index + 1]
            if not suite_value then
                return nil, "--suite requires a value"
            end
            opts.suite_was_set = true
            add_suite_names(opts.requested_suites, suite_value)
            index = index + 2
        elseif value:match("^%-%-suite=") then
            opts.suite_was_set = true
            add_suite_names(opts.requested_suites, value:sub(9))
            index = index + 1
        elseif value == "--filter" then
            opts.filter = argv[index + 1]
            if not opts.filter then
                return nil, "--filter requires a value"
            end
            index = index + 2
        elseif value:match("^%-%-filter=") then
            opts.filter = value:sub(10)
            index = index + 1
        elseif value == "--list" then
            opts.list = true
            index = index + 1
        elseif value == "--fail-fast" then
            opts.fail_fast = true
            index = index + 1
        elseif value == "-v" or value == "--verbose" then
            opts.verbose = true
            index = index + 1
        elseif value == "-h" or value == "--help" then
            opts.help = true
            index = index + 1
        else
            return nil, "unknown option: " .. tostring(value)
        end
    end
    return opts
end

local function known_suites()
    local result = {}
    for _, entry in ipairs(registry) do
        result[entry.suite] = true
    end
    return result
end

local function selected_suites(opts)
    local known = known_suites()
    local selected = {}

    if opts.suite_was_set then
        if opts.requested_suites.all then
            for name in pairs(known) do
                selected[name] = true
            end
        else
            for name in pairs(opts.requested_suites) do
                if not known[name] then
                    return nil, "unknown suite: " .. name
                end
                selected[name] = true
            end
        end
    else
        for _, entry in ipairs(registry) do
            if entry.default then
                selected[entry.suite] = true
            end
        end
    end

    return selected
end

local function list_specs()
    print("Available Oasis test suites:")
    for _, entry in ipairs(registry) do
        local marker = entry.default and "default" or "explicit"
        print(string.format(
            "  %-9s %-8s %s (%s)",
            entry.suite,
            marker,
            entry.description,
            entry.module
        ))
    end
end

local function load_specs(harness, suites)
    for _, entry in ipairs(registry) do
        if suites[entry.suite] then
            local loaded, spec = pcall(require, entry.module)
            if not loaded then
                return false, string.format(
                    "failed to load %s: %s",
                    entry.module,
                    tostring(spec)
                )
            end
            if type(spec) ~= "table" or type(spec.register) ~= "function" then
                return false, entry.module .. " does not export register(harness)"
            end
            local registered, register_error = pcall(function()
                spec.register(harness)
            end)
            if not registered then
                return false, string.format(
                    "failed to register %s: %s",
                    entry.module,
                    tostring(register_error)
                )
            end
        end
    end
    return true
end

function M.main(argv)
    local opts, parse_error = parse_args(argv or {})
    if not opts then
        io.stderr:write("oasis_test: " .. tostring(parse_error) .. "\n")
        usage()
        return 2
    end
    if opts.help then
        usage()
        return 0
    end
    if opts.list then
        list_specs()
        return 0
    end

    local suites, suite_error = selected_suites(opts)
    if not suites then
        io.stderr:write("oasis_test: " .. tostring(suite_error) .. "\n")
        return 2
    end

    local harness = harness_module.new()
    local loaded, load_error = load_specs(harness, suites)
    if not loaded then
        print("Bail out! " .. tostring(load_error))
        return 2
    end

    return harness:run({
        suites = suites,
        filter = opts.filter,
        fail_fast = opts.fail_fast,
        verbose = opts.verbose,
    })
end

return M
