local state = require("oasis.local.tool.state")

local M = {}

local function copy_sections(sections)
    local result = {}
    for index, section in ipairs(sections or {}) do
        local copied = {}
        for key, value in pairs(section) do
            copied[key] = value
        end
        result[index] = copied
    end
    return result
end

local function copy_changes(changes)
    local result = {}
    for index, change in ipairs(changes or {}) do
        local copied = {}
        for item_index, value in ipairs(change) do
            copied[item_index] = value
        end
        result[index] = copied
    end
    return result
end

local function new_uci(sections, options)
    options = options or {}
    local initial_sections = copy_sections(sections)
    local fixture = {
        sections = copy_sections(sections),
        foreach_calls = 0,
        set_calls = {},
        changes_calls = 0,
        pending_changes = copy_changes(options.pending_changes),
        commit_calls = 0,
        revert_calls = 0,
    }

    function fixture:foreach(config, section_type, callback)
        self.foreach_calls = self.foreach_calls + 1
        if options.foreach_raises then
            error("fixture foreach failure")
        end
        if options.foreach_error then
            return false, options.foreach_error
        end
        for _, section in ipairs(self.sections) do
            callback(section)
        end
        if options.foreach_returns_false then
            return false, nil
        end
        return true
    end

    function fixture:changes(config)
        self.changes_calls = self.changes_calls + 1
        if options.changes_raises then
            error("fixture changes failure")
        end
        if options.changes_result ~= nil then
            return options.changes_result
        end
        return copy_changes(self.pending_changes)
    end

    function fixture:set(config, section_name, option, value)
        self.set_calls[#self.set_calls + 1] = {
            config = config,
            section = section_name,
            option = option,
            value = value,
        }
        if options.set_raises then
            error("fixture set failure")
        end
        if options.set_result == false
            or (options.restore_set_result == false
                and #self.set_calls > 1) then
            return false
        end
        for _, section in ipairs(self.sections) do
            if section[".name"] == section_name then
                section[option] = value
            end
        end
        self.pending_changes[#self.pending_changes + 1] = {
            "set",
            section_name,
            option,
            value,
        }
        return true
    end

    function fixture:revert(config)
        self.revert_calls = self.revert_calls + 1
        if options.revert_raises then
            error("fixture revert failure")
        end
        if options.revert_result == false then
            return false
        end
        self.sections = copy_sections(initial_sections)
        return true
    end

    function fixture:commit(config)
        self.commit_calls = self.commit_calls + 1
        for _, change in ipairs(options.commit_injected_changes or {}) do
            self.pending_changes[#self.pending_changes + 1] = copy_changes({
                change,
            })[1]
        end
        if options.commit_raises then
            error("fixture commit failure")
        end
        if options.commit_result == false then
            return false
        end
        self.pending_changes = {}
        return true
    end

    return fixture
end

local function tool(section, server, name, enable, conflict, description)
    return {
        [".name"] = section,
        server = server,
        name = name,
        enable = enable,
        conflict = conflict,
        description = description,
    }
end

function M.register(harness)
    harness:test("unit", "tool state list is normalized and deterministic", function(t)
        t:assert_equal(2, state.TOOL_SEARCH_ABI)
        local uci = new_uci({
            tool("third", "zeta", "beta", true, false, "third"),
            tool("second", "alpha", "zeta", "0", "1", "second"),
            tool("first", "alpha", "alpha", 1, 0, "first"),
        })

        local result = state.list(uci)
        t:assert_equal("OK", result.status)
        t:assert_equal(3, #result.tool)
        t:assert_equal("alpha", result.tool[1].server)
        t:assert_equal("alpha", result.tool[1].name)
        t:assert_equal("1", result.tool[1].enable)
        t:assert_true(result.tool[1].enabled)
        t:assert_false(result.tool[1].conflicted)
        t:assert_equal("zeta", result.tool[2].name)
        t:assert_false(result.tool[2].enabled)
        t:assert_true(result.tool[2].conflicted)
        t:assert_equal("zeta", result.tool[3].server)
        t:assert_nil(result.tool[1].section,
            "internal UCI section names must not be exposed")
    end)

    harness:test("unit", "empty UCI registry is distinct from a read failure", function(t)
        local empty = new_uci({}, { foreach_returns_false = true })
        local empty_result = state.list(empty)
        t:assert_equal("OK", empty_result.status)
        t:assert_equal(0, #empty_result.tool)

        local failed = new_uci({}, { foreach_error = "ubus unavailable" })
        local failed_result = state.list(failed)
        t:assert_equal("NG", failed_result.status)
        t:assert_equal("uci_read_failed", failed_result.code)
        t:assert_type("table", failed_result.tool)
        t:assert_equal(0, #failed_result.tool)

        local raised = new_uci({}, { foreach_raises = true })
        t:assert_equal("uci_read_failed", state.list(raised).code)
    end)

    harness:test("unit", "tool state requires an unambiguous server and name", function(t)
        local unique = new_uci({
            tool("one", "server-a", "scan", "0", "0"),
        })
        t:assert_equal("missing_server",
            state.set_enabled(unique, nil, "scan", true).code)
        t:assert_equal("missing_tool",
            state.set_enabled(unique, "server-a", nil, true).code)
        t:assert_equal("invalid_enable",
            state.set_enabled(unique, "server-a", "scan", "yes").code)
        t:assert_equal("tool_not_found",
            state.set_enabled(unique, "server-b", "scan", true).code)

        local duplicate = new_uci({
            tool("one", "server-a", "scan", "0", "0"),
            tool("two", "server-a", "scan", "1", "0"),
        })
        local result = state.set_enabled(duplicate, "server-a", "scan", true)
        t:assert_equal("NG", result.status)
        t:assert_equal("duplicate_tool", result.code)
        t:assert_equal(0, #duplicate.set_calls)
        t:assert_equal(0, duplicate.commit_calls)
    end)

    harness:test("unit", "conflicted tools cannot be changed", function(t)
        local uci = new_uci({
            tool("blocked", "server-a", "scan", "0", "1"),
        })
        local result = state.set_enabled(uci, "server-a", "scan", true)
        t:assert_equal("NG", result.status)
        t:assert_equal("tool_conflict", result.code)
        t:assert_equal(0, #uci.set_calls)
        t:assert_equal(0, uci.commit_calls)

        local stale_flags = new_uci({
            tool("one", "server-a", "scan", "0", "0"),
            tool("two", "server-b", "scan", "0", "0"),
        })
        local stale_result = state.set_enabled(
            stale_flags, "server-a", "scan", true)
        t:assert_equal("tool_conflict", stale_result.code)
        t:assert_equal(0, #stale_flags.set_calls)
        local listed = state.list(stale_flags)
        t:assert_true(listed.tool[1].conflicted)
        t:assert_true(listed.tool[2].conflicted)
    end)

    harness:test("unit", "tool state changes are idempotent and committed once", function(t)
        local unchanged = new_uci({
            tool("same", "server-a", "scan", "1", "0"),
        })
        local same_result = state.set_enabled(
            unchanged, "server-a", "scan", true)
        t:assert_equal("OK", same_result.status)
        t:assert_false(same_result.changed)
        t:assert_true(same_result.enabled)
        t:assert_equal(0, #unchanged.set_calls)
        t:assert_equal(0, unchanged.changes_calls,
            "an idempotent request should not inspect or alter staged state")
        t:assert_equal(0, unchanged.commit_calls)

        local changed = new_uci({
            tool("change", "server-a", "scan", "0", "0"),
        })
        local changed_result = state.set_enabled(
            changed, "server-a", "scan", true)
        t:assert_equal("OK", changed_result.status)
        t:assert_true(changed_result.changed)
        t:assert_equal("1", changed_result.enable)
        t:assert_true(changed_result.enabled)
        t:assert_equal(1, #changed.set_calls)
        t:assert_equal("change", changed.set_calls[1].section)
        t:assert_equal("1", changed.set_calls[1].value)
        t:assert_equal(1, changed.commit_calls)
    end)

    harness:test("unit", "tool state refuses pre-existing Oasis deltas", function(t)
        local unrelated = {
            { "set", "general", "provider", "anthropic" },
        }
        local pending = new_uci({
            tool("change", "server-a", "scan", "0", "0"),
        }, { pending_changes = unrelated })

        local result = state.set_enabled(
            pending, "server-a", "scan", true)
        t:assert_equal("NG", result.status)
        t:assert_equal("uci_pending_changes", result.code)
        t:assert_false(result.changed)
        t:assert_equal(1, pending.changes_calls)
        t:assert_equal(0, #pending.set_calls)
        t:assert_equal(0, pending.commit_calls)
        t:assert_equal(0, pending.revert_calls)
        t:assert_equal("0", pending.sections[1].enable)
        t:assert_deep_equal(unrelated, pending.pending_changes,
            "the unrelated staged delta must remain untouched")

        local unreadable = new_uci({
            tool("change", "server-a", "scan", "0", "0"),
        }, { changes_raises = true })
        local unreadable_result = state.set_enabled(
            unreadable, "server-a", "scan", true)
        t:assert_equal("uci_changes_failed", unreadable_result.code)
        t:assert_equal(0, #unreadable.set_calls)
        t:assert_equal(0, unreadable.commit_calls)

        local unsupported = new_uci({
            tool("change", "server-a", "scan", "0", "0"),
        })
        unsupported.changes = nil
        t:assert_equal("uci_changes_failed", state.set_enabled(
            unsupported, "server-a", "scan", true).code)
        t:assert_equal(0, #unsupported.set_calls)
    end)

    harness:test("unit", "UCI write failures are closed and rollback staged state", function(t)
        local set_failed = new_uci({
            tool("set-fail", "server-a", "scan", "0", "0"),
        }, { set_result = false })
        local set_result = state.set_enabled(
            set_failed, "server-a", "scan", true)
        t:assert_equal("uci_set_failed", set_result.code)
        t:assert_false(set_result.changed)
        t:assert_equal(0, set_failed.commit_calls)

        local commit_failed = new_uci({
            tool("commit-fail", "server-a", "scan", "0", "0"),
        }, { commit_result = false })
        local commit_result = state.set_enabled(
            commit_failed, "server-a", "scan", true)
        t:assert_equal("uci_commit_failed", commit_result.code)
        t:assert_false(commit_result.changed)
        t:assert_equal(2, #commit_failed.set_calls)
        t:assert_equal("0", commit_failed.set_calls[2].value)
        t:assert_equal(0, commit_failed.revert_calls,
            "rollback must not revert the whole Oasis config")
        t:assert_equal("0", commit_failed.sections[1].enable)
        t:assert_equal(1, commit_failed.commit_calls)

        local preserve_unrelated = new_uci({
            tool("restore", "server-a", "scan", "0", "0"),
        }, {
            commit_result = false,
            commit_injected_changes = {
                { "set", "general", "provider", "gemini" },
            },
        })
        local restore_result = state.set_enabled(
            preserve_unrelated, "server-a", "scan", true)
        t:assert_equal("uci_commit_failed", restore_result.code)
        t:assert_equal(2, #preserve_unrelated.set_calls)
        t:assert_equal("0", preserve_unrelated.set_calls[2].value)
        t:assert_equal("0", preserve_unrelated.sections[1].enable)
        t:assert_equal(0, preserve_unrelated.revert_calls)
        t:assert_deep_equal(
            { "set", "general", "provider", "gemini" },
            preserve_unrelated.pending_changes[2],
            "commit failure rollback must preserve a concurrent delta"
        )

        local rollback_failed = new_uci({
            tool("rollback-fail", "server-a", "scan", "0", "0"),
        }, {
            commit_result = false,
            restore_set_result = false,
        })
        local rollback_result = state.set_enabled(
            rollback_failed, "server-a", "scan", true)
        t:assert_equal("uci_rollback_failed", rollback_result.code)
        t:assert_false(rollback_result.changed)

        local raised = new_uci({
            tool("raise", "server-a", "scan", "0", "0"),
        }, { set_raises = true })
        t:assert_equal("uci_set_failed",
            state.set_enabled(raised, "server-a", "scan", true).code)
    end)

    harness:test("unit", "Tool Search cannot disable its own control plane", function(t)
        local protected = new_uci({
            tool("control", "oasis.tool.manager", "set_tool_enabled", "1", "0"),
        })
        local denied = state.set_enabled(
            protected,
            "oasis.tool.manager",
            "set_tool_enabled",
            false
        )
        t:assert_equal("protected_control_tool", denied.code)
        t:assert_equal(0, #protected.set_calls)

        local explicit = new_uci({
            tool("control", "oasis.tool.manager", "set_tool_enabled", "1", "0"),
        })
        local allowed = state.set_enabled(
            explicit,
            "oasis.tool.manager",
            "set_tool_enabled",
            false,
            { allow_control_disable = true }
        )
        t:assert_equal("OK", allowed.status)
        t:assert_true(allowed.changed)
        t:assert_false(allowed.enabled)
        t:assert_equal(1, explicit.commit_calls)
    end)

    harness:test("unit", "legacy name-only updates require a unique tool name", function(t)
        local unique = new_uci({
            tool("unique", "server-a", "scan", "0", "0"),
        })
        local result = state.set_enabled_by_name(unique, "scan", true)
        t:assert_equal("OK", result.status)
        t:assert_true(result.changed)
        t:assert_equal("server-a", result.server)

        local ambiguous = new_uci({
            tool("one", "server-a", "scan", "0", "0"),
            tool("two", "server-b", "scan", "0", "0"),
        })
        local ambiguous_result = state.set_enabled_by_name(
            ambiguous, "scan", true)
        t:assert_equal("NG", ambiguous_result.status)
        t:assert_equal("duplicate_tool", ambiguous_result.code)
        t:assert_equal(0, #ambiguous.set_calls)
    end)

    harness:test("unit", "persistent tool state stages only in a private transaction", function(t)
        local original = new_uci({
            tool("original", "server-a", "scan", "0", "0"),
        })
        local private = new_uci({
            tool("private", "server-a", "scan", "0", "0"),
        })
        local calls = 0
        local saved_transaction = package.loaded[
            "oasis.local.tool.uci_transaction"]
        package.loaded["oasis.local.tool.uci_transaction"] = {
            run = function(options, callback)
                calls = calls + 1
                t:assert_equal(original, options.cursor)
                t:assert_equal("oasis", options.config)
                local ok, result, code = callback(private)
                t:assert_true(ok, tostring(code))
                result.warning = "fixture cleanup warning"
                return true, result
            end,
        }

        local called, result_or_err = pcall(
            state.set_enabled_persistent,
            original,
            "server-a",
            "scan",
            true
        )
        package.loaded["oasis.local.tool.uci_transaction"] =
            saved_transaction

        t:assert_true(called, tostring(result_or_err))
        local result = result_or_err
        t:assert_equal("OK", result.status)
        t:assert_true(result.changed)
        t:assert_contains(result.warning, "cleanup warning")
        t:assert_equal(1, calls)
        t:assert_equal(0, #original.set_calls)
        t:assert_equal(0, original.commit_calls)
        t:assert_equal(1, #private.set_calls)
        t:assert_equal(0, private.changes_calls,
            "the common transaction owns clean-state checks")
        t:assert_equal(0, private.commit_calls,
            "the common transaction owns the commit")
    end)

    harness:test("unit", "persistent idempotence still uses the isolated transaction", function(t)
        local original = new_uci({
            tool("original", "server-a", "scan", "1", "0"),
        }, {
            pending_changes = {
                { "set", "general", "provider", "pending" },
            },
        })
        local private = new_uci({
            tool("private", "server-a", "scan", "1", "0"),
        })
        local calls = 0
        local module_name = "oasis.local.tool.uci_transaction"
        local saved_transaction = package.loaded[module_name]
        t:on_cleanup(function()
            package.loaded[module_name] = saved_transaction
        end)
        package.loaded[module_name] = {
            run = function(options, callback)
                calls = calls + 1
                t:assert_equal(original, options.cursor)
                local ok, result, code = callback(private)
                t:assert_true(ok, tostring(code))
                return true, result
            end,
        }

        local result = state.set_enabled_persistent(
            original, "server-a", "scan", true)
        t:assert_equal("OK", result.status)
        t:assert_false(result.changed)
        t:assert_true(result.enabled)
        t:assert_equal(1, calls)
        t:assert_equal(0, #private.set_calls)
        t:assert_equal(0, private.commit_calls)
        t:assert_equal(0, original.changes_calls,
            "only the common transaction may inspect shared pending state")
        t:assert_equal(1, #original.pending_changes,
            "the source cursor must remain untouched")
    end)

    harness:test("unit", "persistent name-only updates preserve private failures", function(t)
        local original = new_uci({
            tool("original", "server-a", "scan", "0", "0"),
        })
        local private_unique = new_uci({
            tool("private", "server-a", "scan", "0", "0"),
        })
        local private_ambiguous = new_uci({
            tool("one", "server-a", "scan", "0", "0"),
            tool("two", "server-b", "scan", "0", "0"),
        })
        local calls = 0
        local module_name = "oasis.local.tool.uci_transaction"
        local saved_transaction = package.loaded[module_name]
        t:on_cleanup(function()
            package.loaded[module_name] = saved_transaction
        end)
        package.loaded[module_name] = {
            run = function(_, callback)
                calls = calls + 1
                local private = calls == 1
                    and private_unique or private_ambiguous
                local ok, result, code = callback(private)
                return ok, result, code
            end,
        }

        local changed = state.set_enabled_by_name_persistent(
            original, "scan", true)
        t:assert_equal("OK", changed.status)
        t:assert_true(changed.changed)
        t:assert_equal("server-a", changed.server)
        t:assert_equal(1, #private_unique.set_calls)
        t:assert_equal(0, private_unique.commit_calls)

        local ambiguous = state.set_enabled_by_name_persistent(
            original, "scan", true)
        t:assert_equal("NG", ambiguous.status)
        t:assert_equal("duplicate_tool", ambiguous.code)
        t:assert_false(ambiguous.changed)
        t:assert_equal(0, #private_ambiguous.set_calls)
        t:assert_equal(2, calls)
        t:assert_equal(0, #original.set_calls)
        t:assert_equal(0, original.commit_calls)
    end)

    harness:test("unit", "persistent transaction failures retain their safety code", function(t)
        local original = new_uci({
            tool("original", "server-a", "scan", "0", "0"),
        })
        local module_name = "oasis.local.tool.uci_transaction"
        local saved_transaction = package.loaded[module_name]
        t:on_cleanup(function()
            package.loaded[module_name] = saved_transaction
        end)
        package.loaded[module_name] = {
            run = function()
                return false,
                    "Oasis tool state has pending UCI changes",
                    "uci_pending_changes"
            end,
        }

        local pending = state.set_enabled_persistent(
            original, "server-a", "scan", true)
        t:assert_equal("NG", pending.status)
        t:assert_equal("uci_pending_changes", pending.code)
        t:assert_contains(pending.error, "pending UCI changes")
        t:assert_equal("server-a", pending.server)
        t:assert_equal("scan", pending.tool)
        t:assert_equal(0, #original.set_calls)

        package.loaded[module_name] = {
            run = function()
                error("injected transaction exception")
            end,
        }
        local raised = state.set_enabled_persistent(
            original, "server-a", "scan", true)
        t:assert_equal("NG", raised.status)
        t:assert_equal("uci_transaction_failed", raised.code)
        t:assert_contains(raised.error, "isolated UCI transaction failed")
        t:assert_equal(0, original.commit_calls)
    end)
end

return M
