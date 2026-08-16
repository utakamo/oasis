#!/usr/bin/env lua

-- Compatibility entry point for the original one-off regression test. The
-- assertions now live in the shared provider suite so they are also executed
-- by the default oasis_test command.
local loaded, runner = pcall(require, "oasis.test.runner")
if not loaded then
    io.stderr:write("oasis_user_only_sanitizer_test: failed to load runner: "
        .. tostring(runner) .. "\n")
    os.exit(2)
end

local argv = {
    "--suite", "provider",
    "--filter", "user_only",
}
for _, value in ipairs(arg or {}) do
    argv[#argv + 1] = value
end

os.exit(runner.main(argv))
