local M = {}

function M.register(harness)
    harness:test("device", "core Lua modules load from the installed package", function(t)
        local modules = {
            "oasis.common",
            "oasis.chat.error",
            "oasis.chat.response_framer",
            "oasis.chat.tool_sequence",
            "oasis.chat.function.calling.policy",
            "oasis.unified.chat.schema",
            "oasis.chat.service.openai",
            "oasis.chat.service.openai_responses",
            "oasis.chat.service.anthropic",
            "oasis.chat.service.gemini",
            "oasis.chat.service.ollama",
            "oasis.chat.service.lmstudio",
            "oasis.local.tool.state",
            "oasis.local.tool.auto_store",
            "oasis.local.tool.uci_transaction",
        }
        for _, module_name in ipairs(modules) do
            local ok, value = pcall(require, module_name)
            t:assert_true(ok, module_name .. ": " .. tostring(value))
            t:assert_type("table", value, module_name)
        end
    end)

    harness:test("device", "core RPC and configuration payloads are installed", function(t)
        local paths = {
            "/usr/bin/oasis",
            "/usr/libexec/rpcd/oasis",
            "/usr/libexec/rpcd/oasis.chat",
            "/usr/libexec/rpcd/oasis.title",
            "/usr/libexec/rpcd/oasis.tool.manager",
            "/usr/bin/oasis_tool_setup",
            "/etc/init.d/olt_tool",
            "/usr/lib/lua/oasis/local/tool/uci_transaction.lua",
            "/usr/lib/lua/oasis/local/tool/auto_store.lua",
            "/usr/share/rpcd/acl.d/oasis.json",
            "/usr/share/rpcd/acl.d/oasis-mod-tool.json",
            "/etc/config/oasis",
            "/etc/oasis/oasis.conf",
            "/etc/oasis/tool-manifest.d/lua.oasis.network.json",
            "/etc/oasis/tool-manifest.d/lua.oasis.service.json",
            "/etc/oasis/tool-manifest.d/lua.oasis.system.json",
            "/etc/oasis/tool-manifest.d/lua.oasis.tool.manager.json",
            "/etc/oasis/tool-manifest.d/lua.oasis.wireless.json",
            "/etc/oasis/tool-manifest.d/ucode.oasis_plugin_server.uc.json",
            "/usr/bin/oasis_test",
            "/usr/bin/oasis_user_only_sanitizer_test",
            "/usr/lib/lua/oasis/test/harness.lua",
            "/usr/lib/lua/oasis/test/registry.lua",
            "/usr/lib/lua/oasis/test/runner.lua",
            "/usr/lib/lua/oasis/test/spec/provider_request.lua",
            "/usr/lib/lua/oasis/test/spec/provider_tool_sequence.lua",
            "/usr/lib/lua/oasis/test/spec/manifest_transaction.lua",
            "/usr/lib/lua/oasis/test/spec/package_initialization.lua",
            "/usr/lib/lua/oasis/test/spec/tool_sequence.lua",
            "/usr/lib/lua/oasis/test/spec/tool_state.lua",
            "/usr/lib/lua/oasis/test/spec/tool_auto.lua",
            "/usr/lib/lua/oasis/test/spec/auto_prompt.lua",
        }
        for _, path in ipairs(paths) do
            local file = io.open(path, "r")
            t:assert_not_nil(file, "missing installed file: " .. path)
            if file then
                file:close()
            end
        end
    end)
end

return M
