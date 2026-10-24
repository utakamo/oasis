local M = {}
function M.register(h)
    h:test("portable","legacy tools mode commands delegate to the shared mode API",function(t)
        local e=require("oasis.test.spec.mode_cli").fixture(t)
        t:assert_equal(0,e.run({"tools","on"}))
        t:assert_equal("1",e.support.tool_auto)
        t:assert_equal(0,e.run({"tools","status"}))
        t:assert_contains(e.stdout,"Mode: agent")
        t:assert_equal(0,e.run({"tools","off"}))
        t:assert_equal("0",e.support.tool_auto)
        t:assert_equal(2,e.commits)
    end)
    h:test("portable","legacy tools mode commands reject invalid or extra arguments",function(t)
        local e=require("oasis.test.spec.mode_cli").fixture(t)
        for _,args in ipairs({{"tools","auto"},{"tools","ON"},{"tools","on","extra"}}) do
            t:assert_equal(2,e.run(args))
        end
        t:assert_equal(0,e.writes)
    end)
end
return M
