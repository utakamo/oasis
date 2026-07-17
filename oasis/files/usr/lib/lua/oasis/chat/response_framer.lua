#!/usr/bin/env lua

local M = {}

local DEFAULT_MAX_BYTES = 4 * 1024 * 1024

local function is_blank(value)
    return tostring(value or ""):match("^%s*$") ~= nil
end

local function fail(state, message)
    state.buffer = ""
    state.parts = {}
    state.part_bytes = 0
    state.failed = true
    state.error = message
    return message
end

local function fail_sse(state, message)
    state.buffer = ""
    state.pending_cr = false
    state.failed = true
    state.error = message
    return message
end

local function check_frame_size(state, frame)
    if #frame <= state.max_bytes then
        return nil
    end

    return fail(state, string.format(
        "AI response record exceeded the %d-byte buffer limit.",
        state.max_bytes
    ))
end

function M.new(streaming, max_bytes)
    return {
        buffer = "",
        parts = {},
        part_bytes = 0,
        streaming = streaming ~= false,
        max_bytes = tonumber(max_bytes) or DEFAULT_MAX_BYTES,
        failed = false,
        error = nil,
    }
end

function M.reset(state, streaming, max_bytes)
    state.buffer = ""
    state.parts = {}
    state.part_bytes = 0
    state.streaming = streaming ~= false
    state.max_bytes = tonumber(max_bytes) or state.max_bytes or DEFAULT_MAX_BYTES
    state.failed = false
    state.error = nil
end

function M.push(state, chunk)
    if state.failed then
        return {}, state.error
    end

    chunk = tostring(chunk or "")

    if not state.streaming then
        local next_size = state.part_bytes + #chunk
        if next_size > state.max_bytes then
            return {}, fail(state, string.format(
                "AI response exceeded the %d-byte buffer limit.",
                state.max_bytes
            ))
        end

        state.parts[#state.parts + 1] = chunk
        state.part_bytes = next_size
        return {}, nil
    end

    state.buffer = state.buffer .. chunk

    local frames = {}
    local start = 1

    while true do
        local newline = state.buffer:find("\n", start, true)
        if not newline then
            break
        end

        local frame = state.buffer:sub(start, newline - 1):gsub("\r$", "")
        start = newline + 1

        if not is_blank(frame) then
            local size_error = check_frame_size(state, frame)
            if size_error then
                return frames, size_error
            end
            frames[#frames + 1] = frame
        end
    end

    state.buffer = state.buffer:sub(start)
    if #state.buffer > state.max_bytes then
        return frames, fail(state, string.format(
            "Incomplete AI response record exceeded the %d-byte buffer limit.",
            state.max_bytes
        ))
    end

    return frames, nil
end

function M.finish(state)
    if state.failed then
        return {}, state.error
    end

    if state.streaming then
        local frame = state.buffer
        state.buffer = ""
        frame = frame:gsub("\r$", "")

        if is_blank(frame) then
            return {}, nil
        end

        local size_error = check_frame_size(state, frame)
        if size_error then
            return {}, size_error
        end

        return { frame }, nil
    end

    local frame = table.concat(state.parts)
    state.parts = {}
    state.part_bytes = 0

    if is_blank(frame) then
        return {}, nil
    end

    return { frame }, nil
end

function M.pending_bytes(state)
    if state.streaming then
        return #(state.buffer or "")
    end
    return tonumber(state.part_bytes) or 0
end

-- Server-Sent Events are separated by a blank line rather than by a single
-- newline. Keep this state separate from the line/JSON record framer above so
-- existing providers retain their current behavior.
function M.new_sse(max_bytes, max_frames)
    return {
        buffer = "",
        pending_cr = false,
        max_bytes = tonumber(max_bytes) or DEFAULT_MAX_BYTES,
        max_frames = tonumber(max_frames),
        frame_count = 0,
        failed = false,
        error = nil,
    }
end

function M.reset_sse(state, max_bytes, max_frames)
    state.buffer = ""
    state.pending_cr = false
    state.max_bytes = tonumber(max_bytes) or state.max_bytes or DEFAULT_MAX_BYTES
    state.max_frames = tonumber(max_frames) or state.max_frames
    state.frame_count = 0
    state.failed = false
    state.error = nil
end

function M.push_sse(state, chunk, eof)
    if state.failed then
        return {}, state.error
    end

    local normalized = ""
    if state.pending_cr then
        normalized = "\r"
        state.pending_cr = false
    end
    normalized = normalized .. tostring(chunk or "")

    -- A CRLF pair may be split between transport chunks. Delay a terminal CR
    -- until the following byte is available before normalizing line endings.
    if not eof and normalized:sub(-1) == "\r" then
        normalized = normalized:sub(1, -2)
        state.pending_cr = true
    end

    normalized = normalized:gsub("\r\n", "\n"):gsub("\r", "\n")
    state.buffer = tostring(state.buffer or "") .. normalized

    local frames = {}
    while true do
        local first, last = state.buffer:find("\n\n", 1, true)
        if not first then
            break
        end

        local frame = state.buffer:sub(1, first - 1)
        state.buffer = state.buffer:sub(last + 1)
        if not is_blank(frame) then
            if #frame > state.max_bytes then
                return frames, fail_sse(state, string.format(
                    "SSE event exceeded the %d-byte buffer limit.",
                    state.max_bytes
                ))
            end
            if state.max_frames and state.frame_count >= state.max_frames then
                return frames, fail_sse(state, string.format(
                    "SSE response exceeded the %d-event limit.",
                    state.max_frames
                ))
            end
            state.frame_count = state.frame_count + 1
            frames[#frames + 1] = frame
        end
    end

    local pending_bytes = #state.buffer + (state.pending_cr and 1 or 0)
    if pending_bytes > state.max_bytes then
        return frames, fail_sse(state, string.format(
            "Incomplete SSE event exceeded the %d-byte buffer limit.",
            state.max_bytes
        ))
    end

    if eof then
        local remaining = state.buffer
        if state.pending_cr then
            remaining = remaining .. "\n"
        end
        state.buffer = ""
        state.pending_cr = false
        if not is_blank(remaining) then
            if #remaining > state.max_bytes then
                return frames, fail_sse(state, string.format(
                    "SSE event exceeded the %d-byte buffer limit.",
                    state.max_bytes
                ))
            end
            if state.max_frames and state.frame_count >= state.max_frames then
                return frames, fail_sse(state, string.format(
                    "SSE response exceeded the %d-event limit.",
                    state.max_frames
                ))
            end
            state.frame_count = state.frame_count + 1
            frames[#frames + 1] = remaining
        end
    end

    return frames, nil
end

function M.pending_sse_bytes(state)
    return #(state.buffer or "") + (state.pending_cr and 1 or 0)
end

return M
