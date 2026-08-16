local framer = require("oasis.chat.response_framer")

local M = {}

local function append_all(target, values)
    for _, value in ipairs(values or {}) do
        target[#target + 1] = value
    end
end

local function collect_line_frames(payload, split_at)
    local state = framer.new(true, 4096)
    local frames = {}
    local first, first_error = framer.push(
        state,
        payload:sub(1, split_at)
    )
    append_all(frames, first)
    if first_error then
        return frames, first_error
    end
    local second, second_error = framer.push(
        state,
        payload:sub(split_at + 1)
    )
    append_all(frames, second)
    if second_error then
        return frames, second_error
    end
    local last, finish_error = framer.finish(state)
    append_all(frames, last)
    return frames, finish_error
end

local function collect_sse_frames(payload, split_at)
    local state = framer.new_sse(4096, 32)
    local frames = {}
    local first, first_error = framer.push_sse(
        state,
        payload:sub(1, split_at),
        false
    )
    append_all(frames, first)
    if first_error then
        return frames, first_error
    end
    local second, second_error = framer.push_sse(
        state,
        payload:sub(split_at + 1),
        true
    )
    append_all(frames, second)
    return frames, second_error
end

function M.register(harness)
    harness:test("portable", "line framing is invariant at every split", function(t)
        local payload = "one\r\n\r\ntwo\nthree"
        local expected = { "one", "two", "three" }
        for split_at = 0, #payload do
            local frames, err = collect_line_frames(payload, split_at)
            t:assert_nil(err, "split=" .. split_at)
            t:assert_deep_equal(expected, frames, "split=" .. split_at)
        end
    end)

    harness:test("portable", "SSE CRLF framing is invariant at every split", function(t)
        local payload = table.concat({
            "event: message\r\n",
            "data: {\"value\":1}\r\n",
            "\r\n",
            "event: done\r\n",
            "data: [DONE]\r\n",
            "\r\n",
        })
        local expected = {
            "event: message\ndata: {\"value\":1}",
            "event: done\ndata: [DONE]",
        }
        for split_at = 0, #payload do
            local frames, err = collect_sse_frames(payload, split_at)
            t:assert_nil(err, "split=" .. split_at)
            t:assert_deep_equal(expected, frames, "split=" .. split_at)
        end
    end)

    harness:test("portable", "non-streaming chunks are joined at EOF", function(t)
        local state = framer.new(false, 16)
        local frames, err = framer.push(state, "abc")
        t:assert_nil(err)
        t:assert_deep_equal({}, frames)
        frames, err = framer.push(state, "def")
        t:assert_nil(err)
        t:assert_deep_equal({}, frames)
        frames, err = framer.finish(state)
        t:assert_nil(err)
        t:assert_deep_equal({ "abcdef" }, frames)
        t:assert_equal(0, framer.pending_bytes(state))
    end)

    harness:test("portable", "line size limit is exact and failure is sticky", function(t)
        local exact = framer.new(true, 3)
        local frames, err = framer.push(exact, "abc\n")
        t:assert_nil(err)
        t:assert_deep_equal({ "abc" }, frames)

        local state = framer.new(true, 3)
        frames, err = framer.push(state, "abcd")
        t:assert_type("string", err)
        t:assert_contains(err, "exceeded")
        t:assert_deep_equal({}, frames)
        t:assert_true(state.failed)

        local repeated_error
        frames, repeated_error = framer.push(state, "ok\n")
        t:assert_equal(err, repeated_error)
        t:assert_deep_equal({}, frames)

        framer.reset(state, true, 3)
        frames, err = framer.push(state, "ok\n")
        t:assert_nil(err)
        t:assert_deep_equal({ "ok" }, frames)
        t:assert_false(state.failed)
    end)

    harness:test("portable", "non-streaming size limit covers all chunks", function(t)
        local state = framer.new(false, 5)
        local frames, err = framer.push(state, "123")
        t:assert_nil(err)
        t:assert_deep_equal({}, frames)
        frames, err = framer.push(state, "456")
        t:assert_type("string", err)
        t:assert_contains(err, "5-byte")
        t:assert_deep_equal({}, frames)
    end)

    harness:test("portable", "SSE event count limit rejects the next event", function(t)
        local state = framer.new_sse(128, 1)
        local frames, err = framer.push_sse(state, "data: one\n\n", false)
        t:assert_nil(err)
        t:assert_deep_equal({ "data: one" }, frames)

        frames, err = framer.push_sse(state, "data: two\n\n", false)
        t:assert_type("string", err)
        t:assert_contains(err, "1-event limit")
        t:assert_deep_equal({}, frames)
        t:assert_true(state.failed)
    end)

    harness:test("portable", "blank input produces no frames", function(t)
        local line_state = framer.new(true, 64)
        local frames, err = framer.push(line_state, "\r\n\n")
        t:assert_nil(err)
        t:assert_deep_equal({}, frames)
        frames, err = framer.finish(line_state)
        t:assert_nil(err)
        t:assert_deep_equal({}, frames)

        local sse_state = framer.new_sse(64, 2)
        frames, err = framer.push_sse(sse_state, "\r\n\r\n", true)
        t:assert_nil(err)
        t:assert_deep_equal({}, frames)
        t:assert_equal(0, framer.pending_sse_bytes(sse_state))
    end)
end

return M
