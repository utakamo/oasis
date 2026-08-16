local M = {}

function M.register(harness)
    harness:test("device", "core Lua modules load from the installed package", function(t)
        local modules = {
            "oasis.common",
            "oasis.chat.error",
            "oasis.chat.response_framer",
            "oasis.unified.chat.schema",
            "oasis.chat.service.openai",
            "oasis.chat.service.openai_responses",
            "oasis.chat.service.anthropic",
            "oasis.chat.service.gemini",
            "oasis.chat.service.ollama",
            "oasis.chat.service.lmstudio",
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
            "/usr/share/rpcd/acl.d/oasis.json",
            "/etc/config/oasis",
            "/etc/oasis/oasis.conf",
            "/usr/bin/oasis_test",
            "/usr/bin/oasis_user_only_sanitizer_test",
            "/usr/lib/lua/oasis/test/harness.lua",
            "/usr/lib/lua/oasis/test/registry.lua",
            "/usr/lib/lua/oasis/test/runner.lua",
            "/usr/lib/lua/oasis/test/spec/provider_request.lua",
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
